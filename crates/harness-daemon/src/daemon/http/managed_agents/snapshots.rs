use std::cmp::Reverse;

use crate::daemon::agent_acp::AcpAgentInspectResponse;
use crate::daemon::protocol::{ManagedAgentListResponse, ManagedAgentSnapshot};
use harness_kernel::errors::CliError;
use harness_protocol::agent::DisconnectReason;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceRuntimeLifecycle, AgentWorkspaceTeamResponse,
};
use harness_protocol::managed_agents::codex::CodexRunStatus;
use harness_protocol::managed_agents::tui::AgentTuiStatus;
use harness_protocol::session::AgentStatus;
use harness_protocol::session::ManagedAgentKind;

use super::super::DaemonHttpState;
use super::{locate_managed_agent_kind, run_terminal_agent_blocking};

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
    requested_kind: Option<ManagedAgentKind>,
) -> Result<ManagedAgentSnapshot, CliError> {
    let kind = match requested_kind {
        Some(kind) => kind,
        None => locate_managed_agent_kind(state, agent_id).await?,
    };
    match kind {
        ManagedAgentKind::Tui => {
            let agent_id = agent_id.to_string();
            run_terminal_agent_blocking(state, "load snapshot", move |manager| {
                manager.get(&agent_id).map(ManagedAgentSnapshot::Terminal)
            })
            .await
        }
        ManagedAgentKind::Codex => state
            .codex_controller
            .run(agent_id)
            .map(ManagedAgentSnapshot::Codex),
        ManagedAgentKind::Acp => state
            .acp_agent_manager
            .get(agent_id)
            .map(ManagedAgentSnapshot::Acp),
    }
}

pub(crate) async fn hydrate_agent_workspace_team_runtime(
    state: &DaemonHttpState,
    response: &mut AgentWorkspaceTeamResponse,
) {
    let Some(team) = response.team.as_mut() else {
        return;
    };
    for member in &mut team.members {
        let Some(identity) = member.managed_identity.as_ref() else {
            continue;
        };
        let lifecycle = match identity.kind {
            ManagedAgentKind::Tui => {
                let id = identity.managed_agent_id.clone();
                run_terminal_agent_blocking(state, "hydrate team runtime", move |manager| {
                    manager.get(&id)
                })
                .await
                .ok()
                .map(|snapshot| tui_lifecycle(snapshot.status))
            }
            ManagedAgentKind::Codex => state
                .codex_controller
                .run(&identity.managed_agent_id)
                .ok()
                .map(|snapshot| codex_lifecycle(snapshot.status)),
            ManagedAgentKind::Acp => state
                .acp_agent_manager
                .get(&identity.managed_agent_id)
                .ok()
                .map(|snapshot| acp_lifecycle(&snapshot.status)),
        };
        if let Some(lifecycle) = lifecycle {
            member.runtime_lifecycle = lifecycle;
            member.runtime_evidence = "live_manager_probe".to_string();
        }
    }
}

const fn tui_lifecycle(status: AgentTuiStatus) -> AgentWorkspaceRuntimeLifecycle {
    match status {
        AgentTuiStatus::Starting | AgentTuiStatus::Running => {
            AgentWorkspaceRuntimeLifecycle::Running
        }
        AgentTuiStatus::Exited | AgentTuiStatus::Stopped => {
            AgentWorkspaceRuntimeLifecycle::Completed
        }
        AgentTuiStatus::Failed => AgentWorkspaceRuntimeLifecycle::Failed,
    }
}

const fn codex_lifecycle(status: CodexRunStatus) -> AgentWorkspaceRuntimeLifecycle {
    match status {
        CodexRunStatus::Queued | CodexRunStatus::Running | CodexRunStatus::WaitingApproval => {
            AgentWorkspaceRuntimeLifecycle::Running
        }
        CodexRunStatus::Completed | CodexRunStatus::Cancelled => {
            AgentWorkspaceRuntimeLifecycle::Completed
        }
        CodexRunStatus::Failed => AgentWorkspaceRuntimeLifecycle::Failed,
    }
}

const fn acp_lifecycle(status: &AgentStatus) -> AgentWorkspaceRuntimeLifecycle {
    match status {
        AgentStatus::Active | AgentStatus::Idle | AgentStatus::AwaitingReview => {
            AgentWorkspaceRuntimeLifecycle::Running
        }
        AgentStatus::Removed => AgentWorkspaceRuntimeLifecycle::Completed,
        AgentStatus::Disconnected { reason, .. } => match reason {
            DisconnectReason::ProcessExited { .. }
            | DisconnectReason::StdioClosed
            | DisconnectReason::TransportClosed
            | DisconnectReason::InitializeTimeout
            | DisconnectReason::PromptTimeout
            | DisconnectReason::WatchdogFired
            | DisconnectReason::OomKilled => AgentWorkspaceRuntimeLifecycle::Recoverable,
            DisconnectReason::UserCancelled
            | DisconnectReason::SessionStopped
            | DisconnectReason::SessionEnded => AgentWorkspaceRuntimeLifecycle::Completed,
            DisconnectReason::AuthRequired
            | DisconnectReason::DaemonShutdown
            | DisconnectReason::Unknown { .. } => AgentWorkspaceRuntimeLifecycle::Unavailable,
        },
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acp_lifecycle_distinguishes_completed_recoverable_and_unavailable_disconnects() {
        for reason in [
            DisconnectReason::UserCancelled,
            DisconnectReason::SessionStopped,
            DisconnectReason::SessionEnded,
        ] {
            assert_eq!(
                acp_lifecycle(&AgentStatus::Disconnected {
                    reason,
                    stderr_tail: None,
                }),
                AgentWorkspaceRuntimeLifecycle::Completed
            );
        }
        assert_eq!(
            acp_lifecycle(&AgentStatus::Disconnected {
                reason: DisconnectReason::TransportClosed,
                stderr_tail: None,
            }),
            AgentWorkspaceRuntimeLifecycle::Recoverable
        );
        assert_eq!(
            acp_lifecycle(&AgentStatus::Disconnected {
                reason: DisconnectReason::AuthRequired,
                stderr_tail: None,
            }),
            AgentWorkspaceRuntimeLifecycle::Unavailable
        );
    }
}
