//! Starts a supported non-Codex reviewer runtime for a durable board attempt.
//!
//! The coordinator drives Codex report runs through `codex_runs`; a non-Codex
//! runtime (`openrouter` today) runs the shared turn through the
//! `agent_turn_runs` store instead. The run is correlated to the attempt's
//! managed run id so start-by-id, restart reconciliation, and admission release
//! all key on the coordinator's attempt rather than a self-generated turn id.

use crate::agents::turn::{AgentTurnRequest, AgentTurnRuntime};
use crate::daemon::agent_acp::{OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation};
use crate::daemon::http::DaemonHttpState;
use harness_kernel::errors::{CliError, CliErrorKind};

/// Everything a non-Codex report start needs from the frozen attempt, apart
/// from the runtime handle the production state supplies.
pub(crate) struct NonCodexReportStart<'a> {
    pub(crate) runtime: &'a str,
    pub(crate) session_id: &'a str,
    pub(crate) project_dir: Option<String>,
    pub(crate) prompt: String,
    pub(crate) requested_model: Option<String>,
    /// The attempt's managed run id; the durable run and its concurrency
    /// admission key on this exact value.
    pub(crate) run_id: &'a str,
    pub(crate) board_item_id: &'a str,
    pub(crate) workflow_execution_id: &'a str,
}

/// Start the named non-Codex runtime for one report attempt, recording it in
/// the `agent_turn_runs` store keyed to the attempt.
///
/// # Errors
///
/// Returns an error when the runtime is not a supported non-Codex runtime, the
/// durable store is unavailable, or the runtime cannot accept the turn.
pub(crate) async fn start_non_codex_report_run(
    state: &DaemonHttpState,
    start: NonCodexReportStart<'_>,
) -> Result<(), CliError> {
    if start.runtime != "openrouter" {
        return Err(CliErrorKind::invalid_transition(format!(
            "unsupported non-Codex reviewer runtime '{}'",
            start.runtime
        ))
        .into());
    }
    let store = state.async_db.get().cloned().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "non-Codex report run needs the canonical async database",
        ))
    })?;
    let runtime = OpenRouterAgentTurnRuntime::new_correlated(
        state.acp_agent_manager.clone(),
        start.session_id.to_string(),
        start.project_dir,
        store,
        OpenRouterRunCorrelation {
            run_id: start.run_id.to_string(),
            board_item_id: Some(start.board_item_id.to_string()),
            workflow_execution_id: Some(start.workflow_execution_id.to_string()),
            task_id: None,
        },
    );
    runtime
        .start(AgentTurnRequest {
            prompt: start.prompt,
            requested_model: start.requested_model,
            pull_request: None,
        })
        .await
        .map(|_| ())
}
