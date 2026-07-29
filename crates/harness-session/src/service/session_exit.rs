use harness_agents::kind::DisconnectReason;

use super::{
    AgentStatus, CURRENT_VERSION, CliError, CliErrorKind, END_SESSION_SIGNAL_ACTION_HINT,
    END_SESSION_SIGNAL_MESSAGE, LeaderTransferPlan, LeaveSignalRecord, Path,
    REMOVE_AGENT_SIGNAL_ACTION_HINT, REMOVE_AGENT_SIGNAL_MESSAGE, SessionAction, SessionRole,
    SessionState, SessionStatus, TaskQueuePolicy, TaskStartSignalRecord, TaskStatus,
    build_leave_signal_record, clear_pending_leader_transfer, ensure_session_can_end,
    leave_signal_delivery_error, plan_leader_transfer, refresh_session, require_active,
    require_active_target_agent, require_endable_session, require_permission,
    require_removable_agent, runtime, touch_agent,
};

/// # Errors
/// Returns [`CliError`] when the session cannot be ended, the actor lacks
/// [`SessionAction::EndSession`], a task is still active, or a leave signal
/// cannot be built for a live agent.
pub fn prepare_end_session_leave_signals(
    state: &SessionState,
    actor_id: &str,
    now: &str,
) -> Result<Vec<LeaveSignalRecord>, CliError> {
    require_endable_session(state)?;
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

/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::RemoveAgent`], `agent_id` is the current leader or not
/// registered, or a leave signal cannot be built for it.
pub fn prepare_remove_agent_leave_signal(
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

/// # Errors
/// Returns [`CliError`] when a signal's runtime is unknown or the runtime
/// fails to write the signal file.
pub fn write_prepared_leave_signals(
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

/// # Errors
/// Returns [`CliError`] when a signal's runtime is unknown or the runtime
/// fails to write the signal file.
pub fn write_prepared_task_start_signals(
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
///
/// # Errors
/// Returns [`CliError`] when the session cannot be ended, the actor lacks
/// [`SessionAction::EndSession`], or a task is still active.
pub fn apply_end_session(
    state: &mut SessionState,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_endable_session(state)?;
    require_permission(state, actor_id, SessionAction::EndSession)?;
    ensure_session_can_end(state)?;

    touch_agent(state, actor_id, now);
    for agent in state.agents.values_mut() {
        if agent.status.is_alive() {
            agent.status = AgentStatus::Disconnected {
                reason: DisconnectReason::SessionEnded,
                stderr_tail: None,
            };
            agent.current_task_id = None;
            agent.updated_at = now.to_string();
            agent.last_activity_at = Some(now.to_string());
        }
    }
    state.leader_id = None;
    state.pending_leader_transfer = None;
    state.status = SessionStatus::Ended;
    refresh_session(state, now);
    Ok(())
}

/// # Errors
/// Returns [`CliError`] when the actor lacks [`SessionAction::EndSession`].
pub fn apply_archive_session(
    state: &mut SessionState,
    actor_id: &str,
    now: &str,
) -> Result<String, CliError> {
    require_permission(state, actor_id, SessionAction::EndSession)?;
    touch_agent(state, actor_id, now);
    state.schema_version = CURRENT_VERSION;
    let archived_at = state.archived_at.clone().unwrap_or_else(|| now.to_string());
    state.archived_at = Some(archived_at.clone());
    refresh_session(state, now);
    Ok(archived_at)
}

/// Change an agent's role. Returns the previous role.
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::AssignRole`], `role` is `Leader`, `agent_id` is the
/// current leader, or `agent_id` does not exist or is not alive.
pub fn apply_assign_role(
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
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::RemoveAgent`], `agent_id` is the current leader, or
/// `agent_id` is not registered.
pub fn apply_remove_agent(
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
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::TransferLeader`], or `new_leader_id` does not exist or
/// is not alive.
pub fn apply_transfer_leader(
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
