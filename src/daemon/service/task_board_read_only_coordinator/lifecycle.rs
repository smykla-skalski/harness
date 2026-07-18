use chrono::{DateTime, Duration, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{
    TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptCasOutcome,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardLifecycleOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionRecord,
};

use super::super::task_board_read_only_runtime::{
    TaskBoardPublishVerification, TaskBoardReadOnlyRuntime,
};
use super::attempts::{invalid_transition, require_human, set_execution_state};
use super::reports::transition_attempt;

pub(super) async fn preflight_publish<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
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
                "publish",
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
        .ok_or_else(|| invalid_transition("PrReview workflow has no frozen exact head"))?;
    if fresh == frozen {
        return Ok(true);
    }
    require_human(
        db,
        &execution.execution_id,
        "exact_head_changed_before_publish",
        "PrReview exact head changed before publish was claimed",
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await?;
    Ok(false)
}

pub(super) async fn reconcile_lifecycle_attempt<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let attempt = prepare_lifecycle_attempt(db, execution, attempt, now).await?;
    match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Publish) => {
            reconcile_publish(db, runtime, execution, &attempt, now).await
        }
        Some(TaskBoardExecutionPhase::Cleanup) => {
            reconcile_cleanup(db, execution, &attempt, now).await
        }
        phase => Err(invalid_transition(format!(
            "lifecycle attempt cannot run in phase {phase:?}"
        ))),
    }
}

async fn prepare_lifecycle_attempt(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<TaskBoardExecutionAttemptRecord, CliError> {
    let starting = if attempt.state == TaskBoardAttemptState::Preparing {
        transition_attempt(
            db,
            attempt,
            TaskBoardAttemptState::Starting,
            now,
            None,
            None,
            None,
        )
        .await?
    } else if attempt.state == TaskBoardAttemptState::Starting {
        attempt.clone()
    } else {
        return Ok(attempt.clone());
    };
    if execution.transition.phase == Some(TaskBoardExecutionPhase::Cleanup)
        && execution.transition.execution_state != TaskBoardExecutionState::Starting
    {
        set_execution_state(
            db,
            &execution.execution_id,
            TaskBoardExecutionState::Starting,
            now,
        )
        .await?;
    }
    Ok(starting)
}

async fn reconcile_publish<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if attempt.state == TaskBoardAttemptState::Starting {
        let Some(claimed) = claim_lifecycle_attempt(db, execution, attempt, now, true).await?
        else {
            return Ok(());
        };
        return match runtime.publish_pr_review(execution).await {
            Ok(outcome) => {
                verify_successful_publish(db, runtime, execution, &claimed, outcome, now).await
            }
            Err(error) => {
                settle_ambiguous_publish(db, runtime, execution, &claimed, &error.to_string(), now)
                    .await
            }
        };
    }
    if attempt.state != TaskBoardAttemptState::Running {
        return Err(invalid_transition(
            "publish attempt was not Starting or Running",
        ));
    }
    if !publish_verification_due(attempt, now)? {
        return Ok(());
    }
    settle_ambiguous_publish(
        db,
        runtime,
        execution,
        attempt,
        "publish outcome was not durably recorded before recovery",
        now,
    )
    .await
}

async fn verify_successful_publish<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    published: TaskBoardLifecycleOutcome,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    match runtime.verify_pr_review_approval(execution).await {
        Ok(TaskBoardPublishVerification::Applied(mut verified)) => {
            verified.mutated = published.mutated;
            complete_lifecycle(db, execution, attempt, verified, now).await
        }
        Ok(TaskBoardPublishVerification::Absent) => {
            mark_publish_unknown(
                db,
                execution,
                attempt,
                "successful approval response was absent during authoritative verification",
                now,
            )
            .await
        }
        Err(error) => mark_publish_unknown(db, execution, attempt, &error.to_string(), now).await,
    }
}

async fn reconcile_cleanup(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError> {
    let attempt = if attempt.state == TaskBoardAttemptState::Starting {
        let Some(claimed) = claim_lifecycle_attempt(db, execution, attempt, now, false).await?
        else {
            return Ok(());
        };
        claimed
    } else if attempt.state == TaskBoardAttemptState::Running {
        attempt.clone()
    } else {
        return Err(invalid_transition(
            "cleanup attempt was not Starting or Running",
        ));
    };
    let outcome = TaskBoardLifecycleOutcome {
        mutated: false,
        terminal: true,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: execution
            .transition
            .pull_request
            .as_ref()
            .map(|pull_request| {
                format!(
                    "https://github.com/{}/pull/{}",
                    pull_request.repository, pull_request.number
                )
            }),
    };
    complete_lifecycle(db, execution, &attempt, outcome, now).await
}

async fn claim_lifecycle_attempt(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
    publish: bool,
) -> Result<Option<TaskBoardExecutionAttemptRecord>, CliError> {
    let mut claimed = attempt.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.updated_at = now.to_string();
    claimed.available_at = publish.then(|| publish_claim_deadline(now)).transpose()?;
    if publish {
        let current_execution = db
            .task_board_workflow_execution(&execution.execution_id)
            .await?
            .ok_or_else(|| invalid_transition("workflow execution disappeared before publish"))?;
        let current = current_execution
            .attempts
            .iter()
            .find(|current| {
                current.action_key == attempt.action_key && current.attempt == attempt.attempt
            })
            .ok_or_else(|| invalid_transition("publish attempt disappeared before claim"))?;
        claimed = current.clone();
        claimed.state = TaskBoardAttemptState::Running;
        claimed.updated_at = now.to_string();
        claimed.available_at = Some(publish_claim_deadline(now)?);
        return db
            .claim_task_board_workflow_side_effect(
                &crate::task_board::TaskBoardWorkflowExecutionCas::from(&current_execution),
                &TaskBoardExecutionAttemptCas::from(current),
                &claimed,
                now,
            )
            .await;
    }
    let outcome = super::super::task_board_workflow_execution::record_workflow_execution_attempt(
        db,
        &TaskBoardExecutionAttemptCas::from(attempt),
        &claimed,
    )
    .await?;
    match outcome {
        TaskBoardExecutionAttemptCasOutcome::Updated(record) => Ok(Some(record)),
        TaskBoardExecutionAttemptCasOutcome::Unchanged(_)
        | TaskBoardExecutionAttemptCasOutcome::Stale(Some(_)) => Ok(None),
        TaskBoardExecutionAttemptCasOutcome::Stale(None) => Err(invalid_transition(
            "lifecycle attempt disappeared during claim",
        )),
    }
}

fn publish_claim_deadline(now: &str) -> Result<String, CliError> {
    DateTime::parse_from_rfc3339(now)
        .map(|value| {
            (value.with_timezone(&Utc)
                + Duration::seconds(TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS))
            .to_rfc3339()
        })
        .map_err(|error| invalid_transition(format!("invalid publish claim timestamp: {error}")))
}

fn publish_verification_due(
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<bool, CliError> {
    let Some(available_at) = attempt.available_at.as_deref() else {
        return Ok(true);
    };
    let available_at = DateTime::parse_from_rfc3339(available_at)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid publish claim deadline: {error}")))?;
    let now = DateTime::parse_from_rfc3339(now)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid publish recovery time: {error}")))?;
    Ok(available_at <= now)
}

async fn settle_ambiguous_publish<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    match runtime.verify_pr_review_approval(execution).await {
        Ok(TaskBoardPublishVerification::Applied(outcome)) => {
            complete_lifecycle(db, execution, attempt, outcome, now).await
        }
        Ok(TaskBoardPublishVerification::Absent) => {
            mark_publish_unknown(db, execution, attempt, detail, now).await
        }
        Err(error) => mark_publish_unknown(db, execution, attempt, &error.to_string(), now).await,
    }
}

async fn complete_lifecycle(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    outcome: TaskBoardLifecycleOutcome,
    now: &str,
) -> Result<(), CliError> {
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Completed,
        now,
        None,
        None,
        Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome)),
    )
    .await?;
    set_execution_state(
        db,
        &execution.execution_id,
        TaskBoardExecutionState::Running,
        now,
    )
    .await
}

async fn mark_publish_unknown(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    now: &str,
) -> Result<(), CliError> {
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Unknown,
        now,
        Some(TaskBoardFailureClass::UnknownOutcome),
        Some(detail),
        None,
    )
    .await?;
    require_human(
        db,
        &execution.execution_id,
        "publish_outcome_unknown",
        "PrReview approval outcome could not be verified authoritatively",
        TaskBoardTerminalOutcomeKind::Unknown,
        now,
    )
    .await
}
