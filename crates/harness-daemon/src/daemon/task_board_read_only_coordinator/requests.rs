use crate::daemon::protocol::CodexRunMode;
use crate::task_board::{
    TASK_BOARD_DEPENDENCY_FIXER_EFFORT, TASK_BOARD_DEPENDENCY_FIXER_MODEL,
    TaskBoardDependencyRouteStatus, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardWorkflowExecutionRecord,
};
use harness_kernel::errors::CliError;
use harness_task_board_codex_requests::{attempt_profile, invalid_transition};
pub(crate) use harness_task_board_codex_requests::{
    codex_attempt_request, remote_codex_attempt_request, run_context, write_task_id,
};

/// What a durable workflow attempt's Codex run is, apart from its prompt.
///
/// Reconciliation needs these to find the run and to confirm its binding, and
/// it must get them without rendering. A configured prompt that cannot render
/// would otherwise stop an attempt that has already finished from ever being
/// harvested: the render came first, so the result was never even loaded.
pub(super) struct AttemptRunIdentity {
    pub(super) mode: CodexRunMode,
    /// Reviewer runtime the resolved profile names. `codex` drives the durable
    /// Codex path; a supported agent-turn runtime (`openrouter`) drives the
    /// shared turn through the `agent_turn_runs` store. Implementation attempts
    /// have no reviewer profile and are Codex-only.
    pub(super) runtime: String,
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
        let dependency_fix = execution
            .artifacts
            .dependency_triage
            .as_ref()
            .is_some_and(|route| route.status == TaskBoardDependencyRouteStatus::FixRequested);
        return Ok(AttemptRunIdentity {
            mode: CodexRunMode::WorkspaceWrite,
            runtime: "codex".to_string(),
            task_id: Some(write_task_id(execution)?.to_string()),
            model: dependency_fix.then(|| TASK_BOARD_DEPENDENCY_FIXER_MODEL.into()),
            effort: dependency_fix.then(|| TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into()),
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
        runtime: profile.runtime.clone(),
        task_id: None,
        model: profile.model.clone(),
        effort: profile.effort.clone(),
    })
}
