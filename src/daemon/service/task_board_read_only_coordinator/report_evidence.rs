use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot};
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardFailureClass,
    TaskBoardLocalAttemptResult, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionRecord,
    task_board_local_attempt_result_expectation, validate_task_board_local_attempt_result,
};

use super::attempts::invalid_transition;
use super::attempts::require_human;
use super::reports::transition_attempt;

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
                "invalid_attempt_result",
                "Codex returned invalid or mismatched workflow result evidence",
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
    let valid = run.run_id == attempt.idempotency_key
        && run.session_id == session_id
        && run.task_id == expected.task_id
        && run.board_item_id.as_deref() == Some(execution.item_id.as_str())
        && run.workflow_execution_id.as_deref() == Some(execution.execution_id.as_str())
        && run.project_dir == context.worktree
        && run.mode == expected.mode
        && run.prompt == expected.prompt
        && run.model == expected.model
        && run.effort == expected.effort;
    if valid {
        Ok(())
    } else {
        Err(invalid_transition(
            "durable Codex run does not match the frozen workflow attempt binding",
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
        .ok_or_else(|| invalid_transition("completed Codex run has no final message"))?;
    let result = serde_json::from_str::<TaskBoardLocalAttemptResult>(message.trim())
        .map_err(|error| invalid_transition(format!("parse workflow attempt result: {error}")))?;
    let expected = task_board_local_attempt_result_expectation(execution, attempt).map_err(|_| {
        invalid_transition("workflow attempt phase has no valid frozen result contract")
    })?;
    validate_task_board_local_attempt_result(&result, &expected).map_err(|_| {
        invalid_transition(
            "workflow attempt result does not match its frozen identity or artifact contract",
        )
    })?;
    Ok(result)
}
