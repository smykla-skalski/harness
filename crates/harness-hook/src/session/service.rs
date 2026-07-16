use std::cmp::Reverse;
use std::path::{Path, PathBuf};

use harness_protocol::agent::{AckResult, DisconnectReason, Signal};
use harness_protocol::session::{
    AgentRegistration, AgentStatus, ManagedAgentId, ManagedAgentRef, RuntimeSessionId,
    SessionMetrics, SessionRole, SessionState, SessionStatus, SessionTransition, TaskQueuePolicy,
    TaskStatus,
};

use crate::agents::runtime;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::{project_context_dir, utc_now};

use super::storage;

const START_TASK_SIGNAL_COMMAND: &str = "request_action";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ResolvedRuntimeSessionAgent {
    pub orchestration_session_id: String,
    pub session_agent_id: String,
}

/// Resolve the live orchestration agent for a runtime session.
///
/// # Errors
/// Returns [`CliError`] when session state is unavailable, unsupported, or ambiguous.
pub fn resolve_session_agent_for_runtime_session(
    project_dir: &Path,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    if let Some(result) = super::daemon::resolve_runtime_session(runtime_name, runtime_session_id) {
        return result;
    }
    let active = storage::load_active_registry_for(project_dir)?;
    let mut matches = Vec::new();
    for session_id in active.sessions.into_keys() {
        let layout = storage::layout_from_project_dir(project_dir, &session_id)?;
        let Some(state) = storage::load_state(&layout)? else {
            continue;
        };
        for (agent_id, agent) in &state.agents {
            if agent.status.is_alive()
                && agent.runtime == runtime_name
                && agent.matches_runtime_session_id(
                    &state.session_id,
                    &RuntimeSessionId::from(runtime_session_id),
                )
            {
                matches.push(ResolvedRuntimeSessionAgent {
                    orchestration_session_id: state.session_id.clone(),
                    session_agent_id: agent_id.clone(),
                });
            }
        }
    }
    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.pop()),
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{runtime_session_id}' for runtime '{runtime_name}' maps to multiple orchestration sessions"
        ))
        .into()),
    }
}

/// Record an agent's acknowledgment of a pending signal.
///
/// # Errors
/// Returns [`CliError`] when session, signal, or transition data cannot be read or updated.
pub fn record_signal_acknowledgment(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(result) =
        super::daemon::record_signal_ack(session_id, agent_id, signal_id, result, project_dir)
    {
        return result;
    }
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    if signal_ack_already_logged(&layout, signal_id)? {
        return Ok(());
    }
    let state = load_state(session_id, project_dir)?;
    let signal = find_signal(&state, agent_id, signal_id, project_dir)?;
    let result = signal
        .as_ref()
        .map_or(result, |signal| normalize_signal_ack_result(signal, result));
    let now = utc_now();
    let mut started_task = None;
    storage::update_state(&layout, |state| {
        if let Some(signal) = signal.as_ref() {
            started_task = apply_signal_ack_result(state, agent_id, signal, result, &now);
            refresh_session(state, &now);
        }
        Ok(())
    })?;
    if let Some(task_id) = started_task {
        storage::append_log_entry(
            &layout,
            SessionTransition::TaskAssigned {
                task_id,
                agent_id: agent_id.to_string(),
            },
            Some(agent_id),
            None,
        )?;
    }
    storage::append_log_entry(
        &layout,
        SessionTransition::SignalAcknowledged {
            signal_id: signal_id.to_string(),
            agent_id: agent_id.to_string(),
            result,
        },
        Some(agent_id),
        None,
    )
}

#[must_use]
pub fn normalize_signal_ack_result(signal: &Signal, result: AckResult) -> AckResult {
    match result {
        AckResult::Accepted if signal_is_expired(&signal.expires_at) => AckResult::Expired,
        _ => result,
    }
}

/// Report whether a session agent is currently alive.
///
/// # Errors
/// Returns [`CliError`] when daemon or local session state cannot be loaded.
pub fn session_agent_is_alive(
    session_id: &str,
    agent_id: &str,
    project_dir: &Path,
) -> Result<bool, CliError> {
    if let Some(result) = super::daemon::session_agent_is_alive(session_id, agent_id) {
        return result;
    }
    Ok(load_state(session_id, project_dir)?
        .agents
        .get(agent_id)
        .is_some_and(|agent| agent.status.is_alive()))
}

/// Mark an agent as having left an orchestration session.
///
/// # Errors
/// Returns [`CliError`] when session state or transition logs cannot be updated.
pub fn leave_session(session_id: &str, agent_id: &str, project_dir: &Path) -> Result<(), CliError> {
    if let Some(result) = super::daemon::leave_session(session_id, agent_id) {
        return result;
    }
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    let now = utc_now();
    storage::update_state(&layout, |state| apply_leave_session(state, agent_id, &now))?;
    storage::append_log_entry(
        &layout,
        SessionTransition::AgentLeft {
            agent_id: agent_id.to_string(),
        },
        Some(agent_id),
        None,
    )
}

/// Associate a managed agent with its runtime session.
///
/// # Errors
/// Returns [`CliError`] when session state is unavailable or the runtime conflicts.
///
/// # Panics
/// Panics if the managed-agent index resolves an agent missing from the session state.
pub fn register_agent_runtime_session(
    session_id: &str,
    runtime_name: &str,
    managed_agent_id: &str,
    runtime_session_id: &str,
    project_dir: &Path,
) -> Result<bool, CliError> {
    if let Some(result) = super::daemon::register_runtime_session(
        session_id,
        runtime_name,
        managed_agent_id,
        runtime_session_id,
        project_dir,
    ) {
        return result;
    }
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    if storage::load_state(&layout)?.is_none() {
        return Ok(false);
    }
    let managed_agent = ManagedAgentRef::tui(ManagedAgentId::from(managed_agent_id));
    let runtime_session_id = RuntimeSessionId::from(runtime_session_id);
    let now = utc_now();
    let mut registered = false;
    let _ = storage::update_state_if_changed(&layout, |state| {
        let Some(agent_id) = state.find_session_agent_id_by_managed_agent(&managed_agent) else {
            return Ok(false);
        };
        let agent = state
            .agent(&agent_id)
            .expect("managed-agent lookup resolved agent");
        if agent.runtime != runtime_name {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' uses runtime '{}' but runtime session registration requested '{runtime_name}'",
                agent.runtime
            ))
            .into());
        }
        if agent.runtime_session_id().as_ref() == Some(&runtime_session_id) {
            return Ok(false);
        }
        let agent = state
            .agent_mut(&agent_id)
            .expect("managed-agent lookup resolved mutable agent");
        agent.agent_session_id = Some(runtime_session_id.to_string());
        agent.updated_at.clone_from(&now);
        agent.last_activity_at = Some(now.clone());
        registered = true;
        Ok(true)
    })?;
    Ok(registered)
}

fn load_state(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    storage::load_state(&layout)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("harness session '{session_id}' not found")).into()
    })
}

fn signal_ack_already_logged(
    layout: &crate::workspace::layout::SessionLayout,
    signal_id: &str,
) -> Result<bool, CliError> {
    Ok(storage::load_log_entries(layout)?.into_iter().any(|entry| {
        matches!(
            entry.transition,
            SessionTransition::SignalAcknowledged { signal_id: existing, .. }
                if existing == signal_id
        )
    }))
}

fn find_signal(
    state: &SessionState,
    agent_id: &str,
    signal_id: &str,
    project_dir: &Path,
) -> Result<Option<Signal>, CliError> {
    let Some(agent) = state.agents.get(agent_id) else {
        return Ok(None);
    };
    let signal_session_id = agent.runtime_session_key(&state.session_id);
    let signal_dir = signal_dir(project_dir, agent.runtime.runtime_name(), signal_session_id);
    let mut signals = runtime::signal::read_pending_signals(&signal_dir)?;
    signals.extend(runtime::signal::read_acknowledged_signals(&signal_dir)?);
    Ok(signals
        .into_iter()
        .find(|signal| signal.signal_id == signal_id))
}

fn signal_dir(project_dir: &Path, runtime_name: &str, session_id: &str) -> PathBuf {
    project_context_dir(project_dir)
        .join("agents/signals")
        .join(runtime_name)
        .join(session_id)
}

fn apply_signal_ack_result(
    state: &mut SessionState,
    agent_id: &str,
    signal: &Signal,
    result: AckResult,
    now: &str,
) -> Option<String> {
    match result {
        AckResult::Accepted => apply_task_start_delivery(state, agent_id, signal, now),
        AckResult::Expired => {
            expire_task_start_delivery(state, agent_id, signal, now);
            None
        }
        AckResult::Rejected | AckResult::Deferred => None,
    }
}

fn apply_task_start_delivery(
    state: &mut SessionState,
    agent_id: &str,
    signal: &Signal,
    now: &str,
) -> Option<String> {
    let task_id = task_id_for_task_start_signal(signal)?;
    let previous = state.tasks.get(task_id)?.assigned_to.clone();
    if let Some(previous) = previous.as_deref()
        && previous != agent_id
    {
        clear_agent_current_task(state, previous, task_id, now);
    }
    let task = state.tasks.get_mut(task_id)?;
    if matches!(
        task.status,
        TaskStatus::Done | TaskStatus::Blocked | TaskStatus::InReview
    ) {
        return None;
    }
    let started = task.status != TaskStatus::InProgress;
    task.assigned_to = Some(agent_id.to_string());
    task.status = TaskStatus::InProgress;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();
    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
    started.then(|| task_id.to_string())
}

fn expire_task_start_delivery(
    state: &mut SessionState,
    agent_id: &str,
    signal: &Signal,
    now: &str,
) {
    let Some(task_id) = task_id_for_task_start_signal(signal) else {
        return;
    };
    let Some(task) = state.tasks.get_mut(task_id) else {
        return;
    };
    if matches!(
        task.status,
        TaskStatus::Done | TaskStatus::Blocked | TaskStatus::InReview
    ) || task.assigned_to.as_deref() != Some(agent_id)
    {
        return;
    }
    task.assigned_to = None;
    task.status = TaskStatus::Open;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();
    clear_agent_current_task(state, agent_id, task_id, now);
}

fn task_id_for_task_start_signal(signal: &Signal) -> Option<&str> {
    if signal.command != START_TASK_SIGNAL_COMMAND {
        return None;
    }
    let task_id = signal
        .payload
        .action_hint
        .as_deref()?
        .strip_prefix("task:")?;
    signal
        .payload
        .message
        .starts_with(&format!("Start work on task {task_id}:"))
        .then_some(task_id)
}

fn signal_is_expired(expires_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(expires_at)
        .is_ok_and(|expires| expires < chrono::Utc::now())
}

fn clear_agent_current_task(state: &mut SessionState, agent_id: &str, task_id: &str, now: &str) {
    if let Some(agent) = state.agents.get_mut(agent_id)
        && agent.current_task_id.as_deref() == Some(task_id)
    {
        agent.current_task_id = None;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}

fn refresh_session(state: &mut SessionState, now: &str) {
    state.updated_at = now.to_string();
    state.last_activity_at = Some(now.to_string());
    state.metrics = SessionMetrics::recalculate(state);
}

fn apply_leave_session(
    state: &mut SessionState,
    agent_id: &str,
    now: &str,
) -> Result<(), CliError> {
    if state.status != SessionStatus::Active {
        return Err(CliErrorKind::session_not_active(format!(
            "session '{}' is {:?}",
            state.session_id, state.status
        ))
        .into());
    }
    let departing_leader = state.leader_id.as_deref() == Some(agent_id);
    let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if !agent.status.is_alive() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is already disconnected"
        ))
        .into());
    }
    agent.status = AgentStatus::Disconnected {
        reason: DisconnectReason::UserCancelled,
        stderr_tail: None,
    };
    agent.updated_at = now.to_string();
    agent.last_activity_at = Some(now.to_string());
    agent.current_task_id = None;
    release_agent_tasks(state, agent_id, now);
    clear_pending_leader_transfer(state, agent_id);
    if departing_leader {
        promote_or_degrade(state, now);
    }
    refresh_session(state, now);
    Ok(())
}

fn release_agent_tasks(state: &mut SessionState, agent_id: &str, now: &str) {
    for task in state.tasks.values_mut() {
        if task.assigned_to.as_deref() == Some(agent_id) && task.status != TaskStatus::Done {
            task.status = TaskStatus::Open;
            task.assigned_to = None;
            task.queue_policy = TaskQueuePolicy::Locked;
            task.queued_at = None;
            task.updated_at = now.to_string();
        }
    }
}

fn clear_pending_leader_transfer(state: &mut SessionState, agent_id: &str) {
    if state
        .pending_leader_transfer
        .as_ref()
        .is_some_and(|request| {
            request.requested_by == agent_id
                || request.current_leader_id == agent_id
                || request.new_leader_id == agent_id
        })
    {
        state.pending_leader_transfer = None;
    }
}

fn promote_or_degrade(state: &mut SessionState, now: &str) {
    if let Some(next) = resolve_auto_successor(state) {
        let previous = state.leader_id.clone().unwrap_or_default();
        update_leader_roles(state, &previous, &next, now);
        state.leader_id = Some(next);
        state.status = SessionStatus::Active;
    } else {
        state.leader_id = None;
        state.status = SessionStatus::LeaderlessDegraded;
    }
}

fn resolve_auto_successor(state: &SessionState) -> Option<String> {
    state
        .policy
        .auto_promotion
        .role_order
        .iter()
        .find_map(|role| {
            state
                .agents
                .values()
                .filter(|agent| agent.status.is_alive() && agent.role == *role)
                .max_by_key(|agent| promotion_key(agent))
                .map(|agent| agent.agent_id.clone())
        })
}

fn promotion_key(agent: &AgentRegistration) -> (i32, Reverse<String>, Reverse<String>) {
    let priority = agent
        .capabilities
        .iter()
        .filter_map(|capability| capability.strip_prefix("priority:"))
        .filter_map(|value| value.parse::<i32>().ok())
        .max()
        .unwrap_or_default();
    (
        priority,
        Reverse(agent.joined_at.clone()),
        Reverse(agent.agent_id.clone()),
    )
}

fn update_leader_roles(state: &mut SessionState, old: &str, new: &str, now: &str) {
    if let Some(agent) = state.agents.get_mut(old) {
        agent.role = SessionRole::Worker;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
    if let Some(agent) = state.agents.get_mut(new) {
        agent.role = SessionRole::Leader;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}
