use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardPhaseVerdict, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowRevisionGuard,
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
    if !ensure_frozen_head(db, runtime, execution, &attempt.action_key, now).await? {
        return Ok(());
    }
    match attempt.artifact.as_ref() {
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
            if result.verdict == TaskBoardPhaseVerdict::Pass {
                advance(db, execution, revisions, now).await?;
            } else {
                require_human(
                    db,
                    &execution.execution_id,
                    "evaluation_requires_human",
                    "read-only evaluation did not produce a passing verdict",
                    TaskBoardTerminalOutcomeKind::HumanRequired,
                    now,
                )
                .await?;
            }
        }
        Some(TaskBoardAttemptResultArtifact::Lifecycle(result)) => {
            validate_lifecycle_artifact(execution, attempt, result.terminal)?;
            advance(db, execution, revisions, now).await?;
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
    action_key: &str,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let fresh = match runtime.resolve_exact_head(execution).await {
        Ok(head) => head,
        Err(error) => {
            super::attempt_recovery::schedule_resolution_retry(
                db,
                execution,
                action_key,
                &error.to_string(),
                now,
            )
            .await?;
            return Ok(false);
        }
    };
    let frozen = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| invalid_transition("read-only workflow has no frozen exact head"))?;
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

fn attempt_matches_unapplied_phase(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> bool {
    match (execution.transition.phase, attempt.artifact.as_ref()) {
        (
            Some(TaskBoardExecutionPhase::Review),
            Some(TaskBoardAttemptResultArtifact::Review(outcome)),
        ) => !execution.artifacts.review_cycles.iter().any(|cycle| {
            cycle
                .outcomes
                .iter()
                .any(|stored| stored.profile_id == outcome.profile_id)
        }),
        (
            Some(TaskBoardExecutionPhase::Evaluate),
            Some(TaskBoardAttemptResultArtifact::Evaluation(_)),
        ) => attempt.action_key == "evaluate",
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
