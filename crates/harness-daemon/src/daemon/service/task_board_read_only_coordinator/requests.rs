use crate::daemon::protocol::CodexRunMode;
use crate::daemon::task_board_codex_requests::{attempt_profile, invalid_transition};
pub(crate) use crate::daemon::task_board_codex_requests::{
    codex_attempt_request, remote_codex_attempt_request, run_context, write_task_id,
};
use crate::task_board::{
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardWorkflowExecutionRecord,
};
use harness_kernel::errors::CliError;

/// What a durable workflow attempt's Codex run is, apart from its prompt.
///
/// Reconciliation needs these to find the run and to confirm its binding, and
/// it must get them without rendering. A configured prompt that cannot render
/// would otherwise stop an attempt that has already finished from ever being
/// harvested: the render came first, so the result was never even loaded.
pub(super) struct AttemptRunIdentity {
    pub(super) mode: CodexRunMode,
    pub(super) task_id: Option<String>,
    pub(super) model: Option<String>,
    pub(super) effort: Option<String>,
}

/// Derive the run identity from the frozen execution and attempt records.
///
/// # Errors
///
/// Returns an error when the phase admits no Codex run, or when the frozen
/// fields the phase needs are missing.
pub(super) fn attempt_run_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<AttemptRunIdentity, CliError> {
    if execution.transition.phase == Some(TaskBoardExecutionPhase::Implementation) {
        return Ok(AttemptRunIdentity {
            mode: CodexRunMode::WorkspaceWrite,
            task_id: Some(write_task_id(execution)?.to_string()),
            model: None,
            effort: None,
        });
    }
    if !matches!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate)
    ) {
        return Err(invalid_transition(
            "Codex Report request requires Review or Evaluate phase",
        ));
    }
    let profile = attempt_profile(execution, attempt)?;
    Ok(AttemptRunIdentity {
        mode: CodexRunMode::Report,
        task_id: None,
        model: profile.model.clone(),
        effort: profile.effort.clone(),
    })
}

