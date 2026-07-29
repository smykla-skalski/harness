use crate::daemon::protocol::CodexRunStatus;
use crate::session::service as session_service;
use crate::session::types::{AgentStatus, ManagedAgentRef, SessionState};

use super::orchestration_registration::TaskBindingRollback;

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
    session_service::apply_rollback_joined_agent(state, session_agent_id, now)
}

pub(super) fn rollback_codex_registration(
    state: &mut SessionState,
    session_agent_id: &str,
    managed_agent: &ManagedAgentRef,
    newly_joined: bool,
    task_binding_rollback: Option<&TaskBindingRollback>,
    now: &str,
) -> bool {
    if newly_joined {
        if task_binding_rollback.is_some()
            && !restore_task_binding(state, session_agent_id, task_binding_rollback, now)
        {
            return false;
        }
        return remove_registered_codex_agent(state, session_agent_id, managed_agent, now);
    }
    if task_binding_rollback.is_none()
        || state
            .agents
            .get(session_agent_id)
            .is_none_or(|agent| !agent.matches_managed_agent(managed_agent))
    {
        return false;
    }
    restore_task_binding(state, session_agent_id, task_binding_rollback, now)
}

fn restore_task_binding(
    state: &mut SessionState,
    session_agent_id: &str,
    rollback: Option<&TaskBindingRollback>,
    now: &str,
) -> bool {
    let Some(rollback) = rollback else {
        return false;
    };
    let task_id = rollback.task.task_id.clone();
    let Some(task) = state.tasks.get(&task_id) else {
        return false;
    };
    let Some(agent) = state.agents.get(session_agent_id) else {
        return false;
    };
    if !serialized_values_match(task, &rollback.bound_task)
        || !serialized_values_match(agent, &rollback.bound_agent)
    {
        return false;
    }
    state.tasks.insert(task_id, rollback.task.clone());
    state
        .agents
        .insert(session_agent_id.to_string(), rollback.agent.clone());
    session_service::refresh_session(state, now);
    true
}

fn serialized_values_match<T: serde::Serialize>(left: &T, right: &T) -> bool {
    matches!(
        (serde_json::to_value(left), serde_json::to_value(right)),
        (Ok(left), Ok(right)) if left == right
    )
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
