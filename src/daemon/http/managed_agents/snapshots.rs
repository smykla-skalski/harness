use std::cmp::Reverse;

use crate::daemon::agent_acp::AcpAgentInspectResponse;
use crate::daemon::protocol::{ManagedAgentListResponse, ManagedAgentSnapshot};
use crate::errors::CliError;

use super::super::DaemonHttpState;

// These helpers only assemble managed-agent payloads. Transport-specific auth,
// feature gates, and response shaping stay in the HTTP/WS wrappers.
pub(crate) fn acp_inspect_response(
    state: &DaemonHttpState,
    session_id: Option<&str>,
) -> Result<AcpAgentInspectResponse, CliError> {
    state.acp_agent_manager.inspect(session_id)
}

pub(crate) fn managed_agent_list_response(
    state: &DaemonHttpState,
    session_id: &str,
) -> Result<ManagedAgentListResponse, CliError> {
    let mut agents: Vec<_> = state
        .agent_tui_manager
        .list(session_id)?
        .tuis
        .into_iter()
        .map(ManagedAgentSnapshot::Terminal)
        .chain(
            state
                .codex_controller
                .list_runs(session_id)?
                .runs
                .into_iter()
                .map(ManagedAgentSnapshot::Codex),
        )
        .chain(
            state
                .acp_agent_manager
                .list(session_id)?
                .into_iter()
                .map(ManagedAgentSnapshot::Acp),
        )
        .collect();
    agents.sort_by_key(|agent| {
        (
            Reverse(agent.updated_at().to_string()),
            agent.session_id().to_string(),
            agent.agent_id().to_string(),
        )
    });
    Ok(ManagedAgentListResponse { agents })
}

pub(crate) fn managed_agent_snapshot(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    if let Ok(snapshot) = state.agent_tui_manager.get(agent_id) {
        return Ok(ManagedAgentSnapshot::Terminal(snapshot));
    }
    if let Ok(snapshot) = state.codex_controller.run(agent_id) {
        return Ok(ManagedAgentSnapshot::Codex(snapshot));
    }
    state
        .acp_agent_manager
        .get(agent_id)
        .map(ManagedAgentSnapshot::Acp)
}
