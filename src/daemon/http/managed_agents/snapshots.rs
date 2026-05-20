use std::cmp::Reverse;

use crate::daemon::agent_acp::AcpAgentInspectResponse;
use crate::daemon::protocol::{ManagedAgentListResponse, ManagedAgentSnapshot};
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::run_terminal_agent_blocking;

// These helpers only assemble managed-agent payloads. Transport-specific auth,
// feature gates, and response shaping stay in the HTTP/WS wrappers.
pub(crate) fn acp_inspect_response(
    state: &DaemonHttpState,
    session_id: Option<&str>,
) -> Result<AcpAgentInspectResponse, CliError> {
    state.acp_agent_manager.inspect(session_id)
}

pub(crate) async fn managed_agent_list_response_async(
    state: &DaemonHttpState,
    session_id: &str,
) -> Result<ManagedAgentListResponse, CliError> {
    let session_id_owned = session_id.to_string();
    let terminal_agents = run_terminal_agent_blocking(state, "list snapshots", move |manager| {
        manager.list(&session_id_owned)
    })
    .await?
    .tuis
    .into_iter()
    .map(ManagedAgentSnapshot::Terminal);
    let mut agents: Vec<_> = terminal_agents
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
    sort_managed_agents(&mut agents);
    Ok(ManagedAgentListResponse { agents })
}

pub(crate) async fn managed_agent_snapshot_async(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let agent_id_owned = agent_id.to_string();
    if let Ok(snapshot) = run_terminal_agent_blocking(state, "load snapshot", move |manager| {
        manager.get(&agent_id_owned)
    })
    .await
    {
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

fn sort_managed_agents(agents: &mut [ManagedAgentSnapshot]) {
    agents.sort_by_key(|agent| {
        (
            Reverse(agent.updated_at().to_string()),
            agent.session_id().to_string(),
            agent.agent_id().to_string(),
        )
    });
}
