use crate::types::{ManagedAgentId, ManagedAgentRef, RuntimeSessionId, SessionAgentId};
use harness_agents::kind::RuntimeKind;

use super::{
    AgentRegistration, AgentStatus, CliError, CliErrorKind, SessionRole, SessionState,
    SessionStatus, build_initial_state, clear_pending_leader_transfer, next_available_agent_id,
    promote_or_degrade, refresh_session, release_agent_tasks, runtime_capabilities, touch_agent,
};

// ---------------------------------------------------------------------------
// Extracted state-mutation functions
//
// These apply business logic to an in-memory `SessionState` without touching
// storage. Both the file-based path (`storage::update_state` closures) and the
// daemon-direct path (SQLite writes) call these same functions so the rules
// are defined once.
// ---------------------------------------------------------------------------

/// Build the initial state for a new session (leader + metadata).
///
/// `pub`, not `pub(crate)`: only this crate's own and the root crate's test
/// helpers call it directly today, but it crosses the crate boundary the
/// same way [`build_new_session_with_policy`] does.
#[must_use]
pub fn build_new_session(
    context: &str,
    title: &str,
    session_id: &str,
    runtime_name: &str,
    agent_session_id: Option<&str>,
    now: &str,
) -> SessionState {
    build_new_session_with_policy(
        context,
        title,
        session_id,
        runtime_name,
        agent_session_id,
        now,
        None,
    )
}

// `pub` rather than `pub(crate)`: the session-index test suite in this same
// crate fixtures sessions through this (reached today via the root crate's
// dev-dependency facade), and the root crate's own daemon and hook code call
// it directly across the crate boundary too.
#[must_use]
pub fn build_new_session_with_policy(
    context: &str,
    title: &str,
    session_id: &str,
    runtime_name: &str,
    agent_session_id: Option<&str>,
    now: &str,
    policy_preset: Option<&str>,
) -> SessionState {
    let _ = (runtime_name, agent_session_id);
    build_initial_state(context, title, session_id, now, policy_preset)
}

#[must_use]
pub fn find_agent_by_managed_agent(
    state: &SessionState,
    managed_agent: &ManagedAgentRef,
) -> Option<SessionAgentId> {
    state.find_session_agent_id_by_managed_agent(managed_agent)
}

fn managed_agent_from_capabilities(capabilities: &[String]) -> Option<ManagedAgentRef> {
    let tui_id = capabilities
        .iter()
        .find_map(|capability| capability.strip_prefix("agent-tui:"))?
        .trim();
    if tui_id.is_empty() {
        return None;
    }
    Some(ManagedAgentRef::tui(ManagedAgentId::from(tui_id)))
}

/// Register a new agent into an existing session state. Returns the assigned
/// agent ID.
///
/// If an agent with the same managed-agent identity already exists, return its
/// ID instead of creating a duplicate registration.
///
/// # Errors
/// Returns [`CliError`] when the session's status does not allow joins.
#[expect(
    clippy::too_many_arguments,
    reason = "session join requires all registration fields; a builder would add indirection without reducing complexity"
)]
pub fn apply_join_session(
    state: &mut SessionState,
    display_name: &str,
    runtime_name: &str,
    role: SessionRole,
    capabilities: &[String],
    agent_session_id: Option<&str>,
    now: &str,
    persona: Option<&str>,
    managed_agent: Option<ManagedAgentRef>,
) -> Result<String, CliError> {
    if !matches!(
        state.status,
        SessionStatus::AwaitingLeader | SessionStatus::Active | SessionStatus::LeaderlessDegraded
    ) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "session '{}' is {:?}; joins require an awaiting_leader, active, or leaderless degraded session",
            state.session_id, state.status
        ))
        .into());
    }

    let managed_agent = managed_agent.or_else(|| managed_agent_from_capabilities(capabilities));
    if let Some(existing_id) = managed_agent
        .as_ref()
        .and_then(|managed_agent| find_agent_by_managed_agent(state, managed_agent))
    {
        return Ok(existing_id.to_string());
    }

    let agent_id = SessionAgentId::from(next_available_agent_id(runtime_name, &state.agents));
    let agent_id_key = agent_id.to_string();
    state.agents.insert(
        agent_id_key.clone(),
        AgentRegistration {
            agent_id: agent_id_key.clone(),
            name: display_name.to_string(),
            runtime: RuntimeKind::from(runtime_name),
            role,
            capabilities: capabilities.to_vec(),
            joined_at: now.to_string(),
            updated_at: now.to_string(),
            status: AgentStatus::Active,
            agent_session_id: agent_session_id.map(ToString::to_string),
            managed_agent,
            last_activity_at: Some(now.to_string()),
            current_task_id: None,
            runtime_capabilities: runtime_capabilities(runtime_name),
            persona: persona.and_then(super::persona::resolve),
            runtime_session_title: None,
        },
    );
    if role == SessionRole::Leader && state.leader_id.is_none() {
        state.leader_id = Some(agent_id_key.clone());
        state.status = SessionStatus::Active;
    }
    refresh_session(state, now);
    Ok(agent_id_key)
}

/// # Errors
/// Returns [`CliError`] when `managed_agent` is already registered under a
/// different runtime.
///
/// # Panics
/// Panics if a managed-agent lookup resolves an agent ID that is then
/// missing from `state.agents`, which would indicate the index and the
/// agent map have gone out of sync.
pub fn apply_register_agent_runtime_session(
    state: &mut SessionState,
    runtime_name: &str,
    managed_agent: &ManagedAgentRef,
    agent_session_id: &str,
    now: &str,
) -> Result<bool, CliError> {
    let runtime_session_id = RuntimeSessionId::from(agent_session_id);
    let Some(agent_id) = find_agent_by_managed_agent(state, managed_agent) else {
        return Ok(false);
    };
    let current_agent_session_id = {
        let agent = state
            .agent(&agent_id)
            .expect("managed-agent lookup resolved agent");
        if agent.runtime != runtime_name {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' uses runtime '{}' but runtime session registration requested '{}'",
                agent.runtime, runtime_name
            ))
            .into());
        }
        agent.runtime_session_id()
    };
    if current_agent_session_id.as_ref() == Some(&runtime_session_id) {
        return Ok(false);
    }
    touch_agent(state, agent_id.as_str(), now);
    let agent = state
        .agent_mut(&agent_id)
        .expect("managed-agent lookup resolved mutable agent");
    agent.agent_session_id = Some(runtime_session_id.into_inner());
    Ok(true)
}

/// Record the title a runtime reports for its own session.
///
/// Returns whether the stored title changed, so callers can skip a persist.
///
/// # Panics
/// Panics if a managed-agent lookup resolves an agent ID that is then
/// missing from `state.agents`, which would indicate the index and the
/// agent map have gone out of sync.
pub fn apply_record_runtime_session_title(
    state: &mut SessionState,
    managed_agent: &ManagedAgentRef,
    title: &str,
    now: &str,
) -> bool {
    let Some(agent_id) = find_agent_by_managed_agent(state, managed_agent) else {
        return false;
    };
    {
        let agent = state
            .agent(&agent_id)
            .expect("managed-agent lookup resolved agent");
        if agent.runtime_session_title.as_deref() == Some(title) {
            return false;
        }
    }
    touch_agent(state, agent_id.as_str(), now);
    let agent = state
        .agent_mut(&agent_id)
        .expect("managed-agent lookup resolved mutable agent");
    agent.runtime_session_title = Some(title.to_owned());
    true
}

/// Remove a just-joined agent registration that never finished startup.
///
/// This is used for daemon-managed agent start failures that happen after the
/// orchestration join was persisted but before the runtime session finished
/// binding into the session ledger.
pub fn apply_rollback_joined_agent(state: &mut SessionState, agent_id: &str, now: &str) -> bool {
    let was_leader = state.leader_id.as_deref() == Some(agent_id);
    if state.agents.remove(agent_id).is_none() {
        return false;
    }
    clear_pending_leader_transfer(state, agent_id);
    release_agent_tasks(state, agent_id, now);
    if was_leader {
        if state.agents.values().any(|agent| agent.status.is_alive()) {
            promote_or_degrade(state, now);
        } else {
            state.leader_id = None;
            state.status = SessionStatus::AwaitingLeader;
        }
    }
    refresh_session(state, now);
    true
}

/// # Errors
/// Returns [`CliError`] when `requested_role` is `Leader`, a leader is
/// already active, and `fallback_role` is absent or also `Leader`.
pub fn resolve_join_role(
    state: &SessionState,
    requested_role: SessionRole,
    fallback_role: Option<SessionRole>,
) -> Result<SessionRole, CliError> {
    if requested_role != SessionRole::Leader || state.leader_id.is_none() {
        return Ok(requested_role);
    }
    fallback_role
        .filter(|role| *role != SessionRole::Leader)
        .ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(
                "leader joins require a non-leader fallback role while a leader is active"
                    .to_string(),
            ))
        })
}
