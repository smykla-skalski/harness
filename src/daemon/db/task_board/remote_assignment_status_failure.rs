use chrono::{DateTime, Utc};
use sqlx::{Sqlite, Transaction, query_scalar};

use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteStatusResponse;
use crate::task_board::{
    TaskBoardAttemptRetryDecision, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardOrchestratorSettings, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionRecord, task_board_attempt_retry_decision,
};

pub(super) async fn settle_failed_remote_attempt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent: &mut TaskBoardWorkflowExecutionRecord,
    attempt: &mut TaskBoardExecutionAttemptRecord,
    response: &RemoteStatusResponse,
    settled_at: &str,
) -> Result<bool, CliError> {
    let settings_json = query_scalar::<_, String>(
        "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote failure retry settings: {error}")))?;
    let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
        .map_err(|error| db_error(format!("decode remote failure retry settings: {error}")))?;
    let timestamp = DateTime::parse_from_rfc3339(settled_at)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| db_error(format!("parse remote failure timestamp: {error}")))?;
    let failure_class = response
        .failure_class
        .ok_or_else(|| db_error("failed remote status has no typed failure class"))?;
    let decision = task_board_attempt_retry_decision(
        &settings.retry,
        &format!("{}:{}", parent.execution_id, attempt.action_key),
        &attempt.action_key,
        attempt.attempt,
        failure_class,
        timestamp,
    );
    let detail = response
        .error_code
        .clone()
        .unwrap_or_else(|| "remote executor reported failure".into());
    attempt.failure_class = Some(failure_class);
    attempt.error = Some(detail.clone());
    attempt.artifact = None;
    attempt.updated_at = settled_at.into();
    let class_label = failure_class_label(failure_class);
    parent
        .artifacts
        .diagnostics
        .push(TaskBoardExecutionDiagnostic {
            code: "remote_attempt_failed".into(),
            message: format!("remote {class_label} failure: {detail}"),
            recorded_at: settled_at.into(),
        });
    match decision {
        TaskBoardAttemptRetryDecision::Retry(retry) => {
            attempt.state = TaskBoardAttemptState::RetryWait;
            attempt.available_at = Some(retry.available_at.clone());
            attempt.completed_at = None;
            parent.transition.execution_state = TaskBoardExecutionState::RetryWait;
            parent.available_at = Some(retry.available_at.clone());
            parent.blocked_reason = None;
            parent.completed_at = None;
            parent.artifacts.retry = Some(retry);
            parent.artifacts.terminal_outcome = None;
            Ok(false)
        }
        TaskBoardAttemptRetryDecision::HumanRequired => {
            let exhausted = failure_class == TaskBoardFailureClass::Transient;
            let parent_settled_at = parent.updated_at.clone();
            attempt.state = TaskBoardAttemptState::Failed;
            attempt.available_at = None;
            attempt.completed_at = Some(settled_at.into());
            parent.transition.execution_state = TaskBoardExecutionState::HumanRequired;
            parent.available_at = None;
            parent.blocked_reason = Some(
                if exhausted {
                    "remote_attempts_exhausted"
                } else {
                    "remote_attempt_non_retryable"
                }
                .into(),
            );
            parent.completed_at = Some(parent_settled_at.clone());
            parent.artifacts.retry = None;
            parent.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
                kind: TaskBoardTerminalOutcomeKind::HumanRequired,
                summary: if exhausted {
                    "remote execution attempts exhausted the deterministic retry policy".into()
                } else {
                    format!("remote {class_label} failure is non-retryable: {detail}")
                },
                recorded_at: parent_settled_at,
            });
            Ok(true)
        }
    }
}

const fn failure_class_label(failure_class: TaskBoardFailureClass) -> &'static str {
    match failure_class {
        TaskBoardFailureClass::Transient => "transient",
        TaskBoardFailureClass::Permanent => "permanent",
        TaskBoardFailureClass::Authentication => "authentication",
        TaskBoardFailureClass::Configuration => "configuration",
        TaskBoardFailureClass::Policy => "policy",
        TaskBoardFailureClass::Conflict => "conflict",
        TaskBoardFailureClass::UnknownOutcome => "unknown_outcome",
    }
}
