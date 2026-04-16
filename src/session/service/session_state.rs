use super::{
    AgentRegistration, AgentStatus, CliError, CliErrorKind, END_SESSION_SIGNAL_ACTION_HINT,
    END_SESSION_SIGNAL_MESSAGE, LeaderTransferPlan, LeaveSignalRecord, Path,
    REMOVE_AGENT_SIGNAL_ACTION_HINT, REMOVE_AGENT_SIGNAL_MESSAGE, SessionAction, SessionRole,
    SessionState, SessionStatus, TaskQueuePolicy, TaskStartSignalRecord, TaskStatus,
    build_initial_state, build_leave_signal_record, clear_pending_leader_transfer,
    ensure_session_can_end, leave_signal_delivery_error, next_available_agent_id,
    plan_leader_transfer, refresh_session, require_active, require_active_target_agent,
    require_permission, require_removable_agent, runtime, runtime_capabilities, touch_agent,
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
#[cfg_attr(
    not(test),
    expect(dead_code, reason = "test helpers build sessions directly")
)]
pub(crate) fn build_new_session(
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

pub(crate) fn build_new_session_with_policy(
    context: &str,
    title: &str,
    session_id: &str,
    runtime_name: &str,
    agent_session_id: Option<&str>,
    now: &str,
    policy_preset: Option<&str>,
) -> SessionState {
    build_initial_state(
        context,
        title,
        session_id,
        runtime_name,
        agent_session_id,
        now,
        policy_preset,
    )
}

/// Find an existing agent whose capabilities include the same
/// `agent-tui:agent-tui-{uuid}` marker. Returns the agent ID if found.
pub(crate) fn find_agent_by_tui_marker(
    state: &SessionState,
    capabilities: &[String],
) -> Option<String> {
    let marker = capabilities
        .iter()
        .find(|capability| capability.starts_with("agent-tui:agent-tui-"))?;
    state
        .agents
        .values()
        .find(|agent| {
            agent
                .capabilities
                .iter()
                .any(|capability| capability == marker)
        })
        .map(|agent| agent.agent_id.clone())
}

/// Register a new agent into an existing session state. Returns the assigned
/// agent ID.
///
/// If an agent with the same `agent-tui:{uuid}` marker capability already
/// exists, return its ID instead of creating a duplicate registration.
#[expect(
    clippy::too_many_arguments,
    reason = "session join requires all registration fields; a builder would add indirection without reducing complexity"
)]
pub(crate) fn apply_join_session(
    state: &mut SessionState,
    display_name: &str,
    runtime_name: &str,
    role: SessionRole,
    capabilities: &[String],
    agent_session_id: Option<&str>,
    now: &str,
    persona: Option<&str>,
) -> Result<String, CliError> {
    require_active(state)?;

    if let Some(existing_id) = find_agent_by_tui_marker(state, capabilities) {
        return Ok(existing_id);
    }

    let agent_id = next_available_agent_id(runtime_name, &state.agents);
    state.agents.insert(
        agent_id.clone(),
        AgentRegistration {
            agent_id: agent_id.clone(),
            name: display_name.to_string(),
            runtime: runtime_name.to_string(),
            role,
            capabilities: capabilities.to_vec(),
            joined_at: now.to_string(),
            updated_at: now.to_string(),
            status: AgentStatus::Active,
            agent_session_id: agent_session_id.map(ToString::to_string),
            last_activity_at: Some(now.to_string()),
            current_task_id: None,
            runtime_capabilities: runtime_capabilities(runtime_name),
            persona: persona.and_then(super::persona::resolve),
        },
    );
    refresh_session(state, now);
    Ok(agent_id)
}

pub(crate) fn resolve_join_role(
    state: &SessionState,
    requested_role: SessionRole,
    fallback_role: Option<SessionRole>,
) -> Result<SessionRole, CliError> {
    if requested_role != SessionRole::Leader {
        return Ok(requested_role);
    }

    if state.leader_id.is_some() {
        return fallback_role
            .filter(|role| *role != SessionRole::Leader)
            .ok_or_else(|| {
                CliError::from(CliErrorKind::session_agent_conflict(
                    "leader joins require a non-leader fallback role while a leader is active"
                        .to_string(),
                ))
            });
    }

    Err(CliError::from(CliErrorKind::session_agent_conflict(
        "direct leader joins are not supported without the promotion/recovery flow".to_string(),
    )))
}

pub(crate) fn prepare_end_session_leave_signals(
    state: &SessionState,
    actor_id: &str,
    now: &str,
) -> Result<Vec<LeaveSignalRecord>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::EndSession)?;
    ensure_session_can_end(state)?;

    state
        .agents
        .values()
        .filter(|agent| agent.status.is_alive())
        .map(|agent| {
            build_leave_signal_record(
                state,
                agent,
                actor_id,
                END_SESSION_SIGNAL_MESSAGE,
                END_SESSION_SIGNAL_ACTION_HINT,
                now,
                "end session",
            )
        })
        .collect()
}

pub(crate) fn prepare_remove_agent_leave_signal(
    state: &SessionState,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<Option<LeaveSignalRecord>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::RemoveAgent)?;
    require_removable_agent(state, agent_id)?;

    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if !agent.status.is_alive() {
        return Ok(None);
    }

    build_leave_signal_record(
        state,
        agent,
        actor_id,
        REMOVE_AGENT_SIGNAL_MESSAGE,
        REMOVE_AGENT_SIGNAL_ACTION_HINT,
        now,
        "remove agent",
    )
    .map(Some)
}

pub(crate) fn write_prepared_leave_signals(
    project_dir: &Path,
    signals: &[LeaveSignalRecord],
    action: &str,
) -> Result<(), CliError> {
    for signal in signals {
        let runtime = runtime::runtime_for_name(&signal.runtime).ok_or_else(|| {
            leave_signal_delivery_error(
                action,
                &signal.agent_id,
                format!("unknown runtime '{}'", signal.runtime),
            )
        })?;
        runtime
            .write_signal(project_dir, &signal.signal_session_id, &signal.signal)
            .map_err(|error| leave_signal_delivery_error(action, &signal.agent_id, error))?;
    }
    Ok(())
}

pub(crate) fn write_prepared_task_start_signals(
    project_dir: &Path,
    signals: &[TaskStartSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        let runtime = runtime::runtime_for_name(&signal.runtime).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "unknown runtime '{}'",
                signal.runtime
            )))
        })?;
        runtime.write_signal(project_dir, &signal.signal_session_id, &signal.signal)?;
    }
    Ok(())
}

/// Mark a session as ended. Validates permissions and active-task constraints.
pub(crate) fn apply_end_session(
    state: &mut SessionState,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::EndSession)?;
    ensure_session_can_end(state)?;

    touch_agent(state, actor_id, now);
    for agent in state.agents.values_mut() {
        if agent.status.is_alive() {
            agent.status = AgentStatus::Disconnected;
            agent.current_task_id = None;
            agent.updated_at = now.to_string();
            agent.last_activity_at = Some(now.to_string());
        }
    }
    state.leader_id = None;
    state.pending_leader_transfer = None;
    state.status = SessionStatus::Ended;
    state.archived_at = Some(now.to_string());
    refresh_session(state, now);
    Ok(())
}

/// Change an agent's role. Returns the previous role.
pub(crate) fn apply_assign_role(
    state: &mut SessionState,
    agent_id: &str,
    role: SessionRole,
    actor_id: &str,
    now: &str,
) -> Result<SessionRole, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignRole)?;
    if role == SessionRole::Leader {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "use transfer-leader to assign leader role to '{agent_id}'"
        ))
        .into());
    }
    if state.leader_id.as_deref() == Some(agent_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "cannot change role for current leader '{agent_id}'; use transfer-leader"
        ))
        .into());
    }

    require_active_target_agent(state, agent_id)?;
    let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    let from_role = agent.role;
    agent.role = role;
    agent.updated_at = now.to_string();
    agent.last_activity_at = Some(now.to_string());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(from_role)
}

/// Remove an agent, returning its in-progress tasks to Open.
pub(crate) fn apply_remove_agent(
    state: &mut SessionState,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::RemoveAgent)?;
    require_removable_agent(state, agent_id)?;

    {
        let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' not found"
            )))
        })?;
        agent.status = AgentStatus::Removed;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
        agent.current_task_id = None;
    }
    clear_pending_leader_transfer(state, agent_id);

    for task in state.tasks.values_mut() {
        if task.assigned_to.as_deref() == Some(agent_id) && !matches!(task.status, TaskStatus::Done)
        {
            task.status = TaskStatus::Open;
            task.assigned_to = None;
            task.queue_policy = TaskQueuePolicy::Locked;
            task.queued_at = None;
            task.updated_at = now.to_string();
            task.blocked_reason = None;
            task.completed_at = None;
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}

/// Plan and optionally apply a leader transfer. Returns the transfer plan
/// so the caller can emit the right log entries.
pub(crate) fn apply_transfer_leader(
    state: &mut SessionState,
    new_leader_id: &str,
    actor_id: &str,
    reason: Option<&str>,
    now: &str,
) -> Result<LeaderTransferPlan, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::TransferLeader)?;
    plan_leader_transfer(state, new_leader_id, actor_id, reason, now)
}
