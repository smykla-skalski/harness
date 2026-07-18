use chrono::{DateTime, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptRetryDecision, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardRetrySchedule, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    task_board_attempt_retry_decision,
};

use super::attempts::{invalid_transition, require_human};

pub(super) async fn recover_terminal_attempt_state(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<bool, CliError> {
    let Some(attempt) = execution
        .attempts
        .iter()
        .filter(|attempt| attempt_action_pending(execution, attempt))
        .max_by_key(|attempt| attempt.attempt)
    else {
        return Ok(false);
    };
    match attempt.state {
        TaskBoardAttemptState::RetryWait
            if execution.transition.execution_state == TaskBoardExecutionState::Pending
                && retry_is_due(attempt, now)? =>
        {
            Ok(false)
        }
        TaskBoardAttemptState::RetryWait => {
            recover_retry_wait(db, execution, attempt, now).await?;
            Ok(true)
        }
        TaskBoardAttemptState::Unknown => {
            require_human(
                db,
                &execution.execution_id,
                "attempt_outcome_unknown",
                "attempt result is unknown; success was not recorded",
                TaskBoardTerminalOutcomeKind::Unknown,
                now,
            )
            .await?;
            Ok(true)
        }
        TaskBoardAttemptState::Failed | TaskBoardAttemptState::Cancelled => {
            require_human(
                db,
                &execution.execution_id,
                "attempt_terminal_without_parent",
                attempt
                    .error
                    .as_deref()
                    .unwrap_or("attempt stopped without durable phase completion"),
                TaskBoardTerminalOutcomeKind::HumanRequired,
                now,
            )
            .await?;
            Ok(true)
        }
        TaskBoardAttemptState::Preparing
        | TaskBoardAttemptState::Starting
        | TaskBoardAttemptState::Running
        | TaskBoardAttemptState::Completed => Ok(false),
    }
}

fn retry_is_due(attempt: &TaskBoardExecutionAttemptRecord, now: &str) -> Result<bool, CliError> {
    let available_at = attempt
        .available_at
        .as_deref()
        .ok_or_else(|| invalid_transition("retry attempt has no availability time"))?;
    let now = DateTime::parse_from_rfc3339(now)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid recovery timestamp: {error}")))?;
    let available_at = DateTime::parse_from_rfc3339(available_at)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid retry availability: {error}")))?;
    Ok(available_at <= now)
}

async fn recover_retry_wait(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError> {
    let retry = TaskBoardRetrySchedule {
        action_key: attempt.action_key.clone(),
        next_attempt: attempt.attempt.saturating_add(1),
        failure_class: attempt
            .failure_class
            .ok_or_else(|| invalid_transition("retry attempt has no failure class"))?,
        available_at: attempt
            .available_at
            .clone()
            .ok_or_else(|| invalid_transition("retry attempt has no availability time"))?,
    };
    super::super::task_board_workflow_execution::schedule_workflow_retry(
        db,
        &TaskBoardWorkflowExecutionCas::from(execution),
        retry,
        TaskBoardExecutionDiagnostic {
            code: "attempt_retry_recovered".into(),
            message: attempt
                .error
                .clone()
                .unwrap_or_else(|| "recovering durable attempt retry".into()),
            recorded_at: now.to_string(),
        },
        now,
    )
    .await?;
    Ok(())
}

fn attempt_action_pending(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> bool {
    match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Review) => attempt
            .action_key
            .strip_prefix("review:")
            .is_some_and(|profile_id| {
                !execution.artifacts.review_cycles.iter().any(|cycle| {
                    cycle
                        .outcomes
                        .iter()
                        .any(|outcome| outcome.profile_id == profile_id)
                })
            }),
        Some(TaskBoardExecutionPhase::Evaluate) => attempt.action_key == "evaluate",
        Some(TaskBoardExecutionPhase::Publish) => attempt.action_key == "publish",
        Some(TaskBoardExecutionPhase::Cleanup) => attempt.action_key == "cleanup",
        _ => false,
    }
}

pub(super) async fn schedule_resolution_retry(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    action_key: &str,
    detail: &str,
    now: &str,
) -> Result<(), CliError> {
    let code = format!("{action_key}_resolution_failed");
    let failed_attempt = execution
        .artifacts
        .diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.code == code)
        .count()
        .saturating_add(1);
    let failed_attempt = u32::try_from(failed_attempt).unwrap_or(u32::MAX);
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let timestamp = DateTime::parse_from_rfc3339(now)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid resolution timestamp: {error}")))?;
    match task_board_attempt_retry_decision(
        &settings.settings.retry,
        &format!("{}:{action_key}:resolution", execution.execution_id),
        action_key,
        failed_attempt,
        TaskBoardFailureClass::Transient,
        timestamp,
    ) {
        TaskBoardAttemptRetryDecision::Retry(retry) => {
            super::super::task_board_workflow_execution::schedule_workflow_retry(
                db,
                &TaskBoardWorkflowExecutionCas::from(execution),
                retry,
                TaskBoardExecutionDiagnostic {
                    code,
                    message: detail.to_string(),
                    recorded_at: now.to_string(),
                },
                now,
            )
            .await?;
        }
        TaskBoardAttemptRetryDecision::HumanRequired => {
            require_human(
                db,
                &execution.execution_id,
                "exact_head_resolution_exhausted",
                "exact-head resolution exhausted the durable retry policy",
                TaskBoardTerminalOutcomeKind::HumanRequired,
                now,
            )
            .await?;
        }
    }
    Ok(())
}
