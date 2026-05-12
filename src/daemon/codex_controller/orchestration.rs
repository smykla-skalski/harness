use crate::daemon::protocol::CodexRunStatus;
use crate::session::service as session_service;
use crate::session::types::{AgentStatus, ManagedAgentRef, SessionState};

pub(super) const fn orchestration_status_for_codex_run(status: CodexRunStatus) -> AgentStatus {
    match status {
        CodexRunStatus::Queued | CodexRunStatus::Running | CodexRunStatus::WaitingApproval => {
            AgentStatus::Active
        }
        CodexRunStatus::Completed | CodexRunStatus::Failed | CodexRunStatus::Cancelled => {
            AgentStatus::Idle
        }
    }
}

pub(super) fn update_codex_orchestration_status(
    state: &mut SessionState,
    session_agent_id: &str,
    managed_agent: &ManagedAgentRef,
    status: AgentStatus,
    now: &str,
) -> bool {
    if !codex_orchestration_status_needs_update(state, session_agent_id, managed_agent, &status) {
        return false;
    }
    let agent = state
        .agents
        .get_mut(session_agent_id)
        .expect("codex orchestration status precheck resolved agent");
    agent.status = status;
    agent.updated_at = now.to_string();
    agent.last_activity_at = Some(now.to_string());
    true
}

pub(super) fn remove_registered_codex_agent(
    state: &mut SessionState,
    session_agent_id: &str,
    managed_agent: &ManagedAgentRef,
    now: &str,
) -> bool {
    if state
        .agents
        .get(session_agent_id)
        .is_none_or(|agent| !agent.matches_managed_agent(managed_agent))
    {
        return false;
    }
    state.agents.remove(session_agent_id);
    session_service::refresh_session(state, now);
    true
}

pub(super) fn codex_orchestration_status_needs_update(
    state: &SessionState,
    session_agent_id: &str,
    managed_agent: &ManagedAgentRef,
    status: &AgentStatus,
) -> bool {
    if !state.status.is_liveness_eligible() {
        return false;
    }
    let Some(agent) = state.agents.get(session_agent_id) else {
        return false;
    };
    if !agent.matches_managed_agent(managed_agent) {
        return false;
    }
    !matches!(
        agent.status,
        AgentStatus::AwaitingReview | AgentStatus::Removed
    ) && agent.status != *status
}
