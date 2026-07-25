use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::CodexRunSnapshot;
use harness_kernel::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardFailureClass,
    TaskBoardLocalAttemptResult, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionRecord,
    task_board_local_attempt_result_expectation, validate_task_board_local_attempt_result,
};

use super::attempts::invalid_transition;
use super::attempts::require_human;
use super::reports::transition_attempt;
use super::requests::AttemptRunIdentity;

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
    expected: &AttemptRunIdentity,
) -> Result<(), CliError> {
    let context = super::requests::run_context(execution)?;
    let session_id = context.session_id.as_str();
    // The prompt is configuration and may have been customized after this
    // attempt started, so the frozen attempt identity is what binds the run.
    let valid = run.run_id == attempt.idempotency_key
        && run.session_id == session_id
        && run.task_id == expected.task_id
        && run.board_item_id.as_deref() == Some(execution.item_id.as_str())
        && run.workflow_execution_id.as_deref() == Some(execution.execution_id.as_str())
        && run.project_dir == context.worktree
        && run.mode == expected.mode
        && run.model == expected.model
        && run.effort == expected.effort;
    if !valid {
        return Err(invalid_transition(
            "durable Codex run does not match the frozen workflow attempt binding",
        ));
    }
    // Best-effort confirmation only. A prompt that still matches is the
    // stronger signal, but one that cannot be rendered says nothing either way,
    // and this attempt's result is already durable.
    if super::requests::codex_attempt_request(execution, attempt)
        .is_ok_and(|current| current.prompt != run.prompt)
    {
        note_attempt_prompt_change(&attempt.idempotency_key);
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::info! macro expands into a chain clippy reads as branchy"
)]
fn note_attempt_prompt_change(idempotency_key: &str) {
    tracing::info!(
        target: "harness::task_board",
        managed_run_id = %idempotency_key,
        "durable attempt run was launched with a different prompt; binding confirmed structurally",
    );
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
    let expected =
        task_board_local_attempt_result_expectation(execution, attempt).map_err(|_| {
            invalid_transition("workflow attempt phase has no valid frozen result contract")
        })?;
    validate_task_board_local_attempt_result(&result, &expected).map_err(|_| {
        invalid_transition(
            "workflow attempt result does not match its frozen identity or artifact contract",
        )
    })?;
    Ok(result)
}
