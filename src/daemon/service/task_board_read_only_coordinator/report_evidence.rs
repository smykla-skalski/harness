use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunSnapshot};
use crate::errors::CliError;
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardFailureClass,
    TaskBoardLocalAttemptResult, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionRecord,
};

use super::attempts::invalid_transition;
use super::attempts::require_human;
use super::reports::transition_attempt;
use super::requests::attempt_profile;

pub(super) async fn accept_completed_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &CodexRunSnapshot,
    now: &str,
) -> Result<(), CliError> {
    let result = match parse_attempt_result(run, execution, attempt) {
        Ok(result) => result,
        Err(error) => {
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Failed,
                now,
                Some(TaskBoardFailureClass::Permanent),
                Some(&error.to_string()),
                None,
            )
            .await?;
            require_human(
                db,
                &execution.execution_id,
                "invalid_report_result",
                "Codex Report returned invalid or mismatched result evidence",
                TaskBoardTerminalOutcomeKind::HumanRequired,
                now,
            )
            .await?;
            return Ok(());
        }
    };
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Completed,
        now,
        None,
        None,
        Some(result.artifact),
    )
    .await?;
    Ok(())
}

pub(super) fn validate_run_binding(
    run: &CodexRunSnapshot,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    expected: &CodexRunRequest,
) -> Result<(), CliError> {
    let context = super::requests::run_context(execution)?;
    let session_id = context.session_id.as_str();
    let profile = attempt_profile(execution, attempt)?;
    let valid = run.run_id == attempt.idempotency_key
        && run.session_id == session_id
        && run.task_id.is_none()
        && run.board_item_id.as_deref() == Some(execution.item_id.as_str())
        && run.workflow_execution_id.as_deref() == Some(execution.execution_id.as_str())
        && run.project_dir == context.worktree
        && run.mode == CodexRunMode::Report
        && run.prompt == expected.prompt
        && run.model == profile.model
        && run.effort == profile.effort;
    if valid {
        Ok(())
    } else {
        Err(invalid_transition(
            "durable Codex run does not match the frozen read-only attempt binding",
        ))
    }
}

pub(super) fn parse_attempt_result(
    run: &CodexRunSnapshot,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardLocalAttemptResult, CliError> {
    let message = run
        .final_message
        .as_deref()
        .ok_or_else(|| invalid_transition("completed Codex Report run has no final message"))?;
    let result = serde_json::from_str::<TaskBoardLocalAttemptResult>(message.trim())
        .map_err(|error| invalid_transition(format!("parse read-only attempt result: {error}")))?;
    let frozen_head = execution.transition.exact_head_revision.as_deref();
    let identity_matches = result.schema_version == TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION
        && result.execution_id == attempt.execution_id
        && result.action_key == attempt.action_key
        && result.attempt == attempt.attempt
        && result.idempotency_key == attempt.idempotency_key
        && frozen_head == Some(result.exact_head_revision.as_str());
    if !identity_matches || !artifact_matches(execution, attempt, &result.artifact) {
        return Err(invalid_transition(
            "read-only attempt result does not match its frozen identity or artifact contract",
        ));
    }
    Ok(result)
}

fn artifact_matches(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    artifact: &TaskBoardAttemptResultArtifact,
) -> bool {
    match artifact {
        TaskBoardAttemptResultArtifact::Review(outcome) => {
            attempt.action_key == format!("review:{}", outcome.profile_id)
                && execution.transition.exact_head_revision.as_deref()
                    == Some(outcome.result.head_revision.as_str())
        }
        TaskBoardAttemptResultArtifact::Evaluation(_) => attempt.action_key == "evaluate",
        TaskBoardAttemptResultArtifact::Lifecycle(_)
        | TaskBoardAttemptResultArtifact::Planning(_)
        | TaskBoardAttemptResultArtifact::Implementation(_) => false,
    }
}
