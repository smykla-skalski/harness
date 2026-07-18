use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardPhaseVerdict, TaskBoardPullRequestIdentity,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, TaskBoardWorkflowRevisionGuard, normalize_repository_slug,
    restart_task_board_workflow_revision,
};

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::attempts::{invalid_transition, require_human};

pub(super) fn unapplied_completed_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Option<&TaskBoardExecutionAttemptRecord> {
    execution.attempts.iter().find(|attempt| {
        attempt.state == TaskBoardAttemptState::Completed
            && attempt_matches_unapplied_phase(execution, attempt)
    })
}

pub(super) async fn ingest_completed_attempt<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if !ensure_frozen_head(db, runtime, execution, attempt, now).await? {
        return Ok(());
    }
    match attempt.artifact.as_ref() {
        Some(TaskBoardAttemptResultArtifact::Implementation(result)) => {
            advance_with_head(db, execution, revisions, &result.head_revision, now).await?;
        }
        Some(TaskBoardAttemptResultArtifact::Review(outcome)) => {
            super::super::task_board_workflow_review::record_workflow_reviewer_outcome(
                db,
                &TaskBoardWorkflowExecutionCas::from(execution),
                outcome.clone(),
                now,
            )
            .await?;
        }
        Some(TaskBoardAttemptResultArtifact::Evaluation(result)) => {
            ingest_evaluation(db, execution, revisions, result.verdict, now).await?;
        }
        Some(TaskBoardAttemptResultArtifact::Lifecycle(result)) => {
            validate_lifecycle_artifact(execution, attempt, result.terminal)?;
            if execution.transition.phase == Some(TaskBoardExecutionPhase::Publish) {
                advance_publication(
                    db,
                    execution,
                    revisions,
                    result.external_url.as_deref(),
                    now,
                )
                .await?;
            } else {
                advance(db, execution, revisions, now).await?;
            }
        }
        Some(TaskBoardAttemptResultArtifact::Planning(_)) => {
            return Err(invalid_transition(
                "read-only workflow received a write result artifact",
            ));
        }
        None => {
            return Err(invalid_transition(
                "completed attempt has no result artifact",
            ));
        }
    }
    Ok(())
}

async fn ensure_frozen_head<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if !ensure_implementation_ancestry(db, runtime, execution, attempt, now).await? {
        return Ok(false);
    }
    let fresh = match runtime.resolve_exact_head(execution).await {
        Ok(head) => head,
        Err(error) => {
            super::attempt_recovery::schedule_resolution_retry(
                db,
                execution,
                &attempt.action_key,
                &error.to_string(),
                now,
            )
            .await?;
            return Ok(false);
        }
    };
    let frozen = expected_attempt_head(execution, attempt)?;
    if fresh != frozen {
        require_human(
            db,
            &execution.execution_id,
            "exact_head_changed",
            "exact head changed before durable phase evidence was applied",
            TaskBoardTerminalOutcomeKind::HumanRequired,
            now,
        )
        .await?;
        return Ok(false);
    }
    Ok(true)
}

async fn ensure_implementation_ancestry<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let Some(TaskBoardAttemptResultArtifact::Implementation(result)) = attempt.artifact.as_ref()
    else {
        return Ok(true);
    };
    let descends = match runtime
        .implementation_result_descends_from_base(execution, result)
        .await
    {
        Ok(descends) => descends,
        Err(error) => {
            super::attempt_recovery::schedule_resolution_retry(
                db,
                execution,
                &attempt.action_key,
                &error.to_string(),
                now,
            )
            .await?;
            return Ok(false);
        }
    };
    if descends {
        return Ok(true);
    }
    require_human(
        db,
        &execution.execution_id,
        "implementation_ancestry_invalid",
        "implementation result does not descend from its reported base",
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await?;
    Ok(false)
}

fn expected_attempt_head<'a>(
    execution: &'a TaskBoardWorkflowExecutionRecord,
    attempt: &'a TaskBoardExecutionAttemptRecord,
) -> Result<&'a str, CliError> {
    if attempt.action_key.starts_with("implementation:") {
        return match attempt.artifact.as_ref() {
            Some(TaskBoardAttemptResultArtifact::Implementation(result)) => {
                Some(result.head_revision.as_str())
            }
            _ => None,
        }
        .ok_or_else(|| invalid_transition("implementation attempt has no exact result head"));
    }
    execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| invalid_transition("workflow has no frozen exact head"))
}

async fn advance(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    now: &str,
) -> Result<(), CliError> {
    super::super::task_board_workflow_execution::advance_workflow_execution(
        db,
        &TaskBoardWorkflowExecutionCas::from(execution),
        revisions,
        execution.transition.pull_request.as_ref(),
        execution.transition.exact_head_revision.as_deref(),
        now,
    )
    .await?;
    Ok(())
}

async fn advance_with_head(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    head: &str,
    now: &str,
) -> Result<(), CliError> {
    super::super::task_board_workflow_execution::advance_workflow_execution(
        db,
        &TaskBoardWorkflowExecutionCas::from(execution),
        revisions,
        execution.transition.pull_request.as_ref(),
        Some(head),
        now,
    )
    .await?;
    Ok(())
}

async fn advance_publication(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    external_url: Option<&str>,
    now: &str,
) -> Result<(), CliError> {
    let observed = external_url.map(parse_pull_request_url).transpose()?;
    let pull_request = publication_identity(execution, observed.as_ref())?;
    super::super::task_board_workflow_execution::advance_workflow_execution(
        db,
        &TaskBoardWorkflowExecutionCas::from(execution),
        revisions,
        pull_request.as_ref(),
        execution.transition.exact_head_revision.as_deref(),
        now,
    )
    .await?;
    Ok(())
}

fn publication_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
    observed: Option<&TaskBoardPullRequestIdentity>,
) -> Result<Option<TaskBoardPullRequestIdentity>, CliError> {
    match (execution.transition.pull_request.as_ref(), observed) {
        (Some(frozen), Some(actual))
            if frozen.repository != actual.repository || frozen.number != actual.number =>
        {
            Err(invalid_transition(
                "workflow publication changed its frozen pull request",
            ))
        }
        (Some(frozen), _) => Ok(Some(frozen.clone())),
        (None, Some(actual)) => Ok(Some(actual.clone())),
        (None, None) => Ok(None),
    }
}

fn parse_pull_request_url(url: &str) -> Result<TaskBoardPullRequestIdentity, CliError> {
    let path = url
        .strip_prefix("https://github.com/")
        .ok_or_else(|| invalid_transition("workflow publication URL is not canonical GitHub"))?;
    let (repository, number) = path
        .split_once("/pull/")
        .ok_or_else(|| invalid_transition("workflow publication URL has no pull request"))?;
    let repository = normalize_repository_slug(Some(repository))
        .ok_or_else(|| invalid_transition("workflow publication repository is invalid"))?;
    let number = number
        .parse::<u64>()
        .ok()
        .filter(|number| *number > 0)
        .ok_or_else(|| invalid_transition("workflow publication pull request is invalid"))?;
    Ok(TaskBoardPullRequestIdentity {
        repository,
        number,
        head: None,
    })
}

async fn ingest_evaluation(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    verdict: TaskBoardPhaseVerdict,
    now: &str,
) -> Result<(), CliError> {
    if verdict == TaskBoardPhaseVerdict::Pass {
        return advance(db, execution, revisions, now).await;
    }
    if verdict == TaskBoardPhaseVerdict::ChangesRequired
        && matches!(
            execution.snapshot.workflow_kind,
            TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
        )
        && execution.artifacts.current_revision_cycle
            < execution.resolved_reviewers.max_revision_cycles
    {
        let mut updated = execution.clone();
        updated.transition = restart_task_board_workflow_revision(&updated.transition)
            .map_err(|error| invalid_transition(error.to_string()))?;
        updated.artifacts.current_revision_cycle += 1;
        updated.blocked_reason = Some("evaluation_changes_required".into());
        updated.updated_at = now.to_string();
        db.compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(execution),
            &updated,
        )
        .await?;
        return Ok(());
    }
    require_human(
        db,
        &execution.execution_id,
        "evaluation_requires_human",
        "workflow evaluation did not produce a passing verdict",
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await
}

fn attempt_matches_unapplied_phase(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> bool {
    match (execution.transition.phase, attempt.artifact.as_ref()) {
        (
            Some(TaskBoardExecutionPhase::Implementation),
            Some(TaskBoardAttemptResultArtifact::Implementation(result)),
        ) => {
            attempt.action_key
                == format!(
                    "implementation:{}",
                    execution.artifacts.current_revision_cycle
                )
                && execution.transition.exact_head_revision.as_deref()
                    == Some(result.base_head_revision.as_str())
        }
        (
            Some(TaskBoardExecutionPhase::Review),
            Some(TaskBoardAttemptResultArtifact::Review(outcome)),
        ) => {
            execution.transition.exact_head_revision.as_deref()
                == Some(outcome.result.head_revision.as_str())
                && !execution.artifacts.review_cycles.iter().any(|cycle| {
                    cycle.revision_cycle == execution.artifacts.current_revision_cycle
                        && cycle
                            .outcomes
                            .iter()
                            .any(|stored| stored.profile_id == outcome.profile_id)
                })
        }
        (
            Some(TaskBoardExecutionPhase::Evaluate),
            Some(TaskBoardAttemptResultArtifact::Evaluation(_)),
        ) => {
            attempt.action_key == "evaluate"
                || attempt.action_key
                    == format!("evaluate:{}", execution.artifacts.current_revision_cycle)
        }
        (
            Some(TaskBoardExecutionPhase::Publish),
            Some(TaskBoardAttemptResultArtifact::Lifecycle(_)),
        ) => attempt.action_key == "publish",
        (
            Some(TaskBoardExecutionPhase::Cleanup),
            Some(TaskBoardAttemptResultArtifact::Lifecycle(_)),
        ) => attempt.action_key == "cleanup",
        _ => false,
    }
}

fn validate_lifecycle_artifact(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    terminal: bool,
) -> Result<(), CliError> {
    let valid = match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Publish) => attempt.action_key == "publish" && !terminal,
        Some(TaskBoardExecutionPhase::Cleanup) => attempt.action_key == "cleanup" && terminal,
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(invalid_transition(
            "lifecycle evidence contradicts its durable workflow phase",
        ))
    }
}
