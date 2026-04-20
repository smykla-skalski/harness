use super::{
    AgentStatus, CliError, CliErrorKind, DaemonClient, Path, SessionRole, SessionState,
    SessionTransition, agent_status_label, agents_service, append_leader_transfer_logs,
    append_leave_signal_logs, apply_assign_role, apply_end_session, apply_join_session,
    apply_remove_agent, apply_transfer_leader, clear_pending_leader_transfer,
    create_initial_session, ensure_known_runtime, log_agent_joined, log_agent_removed,
    log_role_changed, log_session_ended, log_session_started, prepare_end_session_leave_signals,
    prepare_remove_agent_leave_signal, protocol, refresh_session, release_agent_tasks,
    require_active, require_removable_agent, resolve_join_role, resolve_registered_runtime,
    resolve_session_project_dir, slice, storage, utc_now, validate_policy_preset,
    write_prepared_leave_signals,
};

/// Start a new orchestration session and register the caller as leader.
///
/// # Errors
/// Returns `CliError` on storage failures.
///
/// # Panics
/// Panics if the new session state has no leader.
pub fn start_session(
    context: &str,
    title: &str,
    project_dir: &Path,
    runtime_name: Option<&str>,
    session_id: Option<&str>,
) -> Result<SessionState, CliError> {
    start_session_with_policy(context, title, project_dir, runtime_name, session_id, None)
}

/// Start a new session with an optional policy preset for the leader.
///
/// # Errors
/// Returns `CliError` on storage failures.
///
/// # Panics
/// Panics if the new session state has no leader.
pub fn start_session_with_policy(
    context: &str,
    title: &str,
    project_dir: &Path,
    runtime_name: Option<&str>,
    session_id: Option<&str>,
    policy_preset: Option<&str>,
) -> Result<SessionState, CliError> {
    let runtime_name = runtime_name.ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(
            "session start requires --runtime for leader session tracking".to_string(),
        ))
    })?;
    ensure_known_runtime(runtime_name, "session start requires a known runtime")?;
    validate_policy_preset(policy_preset)?;

    if let Some(client) = DaemonClient::try_connect() {
        return client.start_session(&protocol::SessionStartRequest {
            title: title.to_string(),
            context: context.to_string(),
            runtime: runtime_name.to_string(),
            session_id: session_id.map(ToString::to_string),
            project_dir: project_dir.to_string_lossy().into_owned(),
            policy_preset: policy_preset.map(ToString::to_string),
        });
    }

    let now = utc_now();
    let leader_runtime = resolve_registered_runtime(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "session start requires a known runtime, got '{runtime_name}'"
        )))
    })?;
    let leader_agent_session_id =
        agents_service::resolve_known_session_id(leader_runtime, project_dir, None)?;
    let state = create_initial_session(
        context,
        title,
        runtime_name,
        session_id,
        leader_agent_session_id.as_deref(),
        &now,
        project_dir,
        policy_preset,
    )?;
    let leader_id = state
        .leader_id
        .as_deref()
        .expect("new session always has a leader");

    let layout = storage::layout_from_project_dir(project_dir, &state.session_id)?;
    storage::register_active(&layout)?;
    let _ = storage::record_project_origin(project_dir);
    storage::append_log_entry(
        &layout,
        log_session_started(title, context),
        Some(leader_id),
        None,
    )?;

    Ok(state)
}

/// Register an agent into an existing session.
///
/// # Errors
/// Returns `CliError` if the session is not active or on storage failures.
///
/// # Panics
/// Panics if the agent ID was not recorded during the update.
pub fn join_session(
    session_id: &str,
    role: SessionRole,
    runtime_name: &str,
    capabilities: &[String],
    name: Option<&str>,
    project_dir: &Path,
    persona: Option<&str>,
) -> Result<SessionState, CliError> {
    join_session_with_fallback(
        session_id,
        role,
        None,
        runtime_name,
        capabilities,
        name,
        project_dir,
        persona,
    )
}

/// Register an agent into an existing session with an optional fallback role.
///
/// # Errors
/// Returns `CliError` if the session is not active or on storage failures.
///
/// # Panics
/// Panics if the agent ID was not recorded during the update.
#[expect(
    clippy::too_many_arguments,
    reason = "session join transport needs explicit fallback metadata without hiding inputs in a struct"
)]
pub fn join_session_with_fallback(
    session_id: &str,
    role: SessionRole,
    fallback_role: Option<SessionRole>,
    runtime_name: &str,
    capabilities: &[String],
    name: Option<&str>,
    project_dir: &Path,
    persona: Option<&str>,
) -> Result<SessionState, CliError> {
    ensure_known_runtime(runtime_name, "agent join requires a known runtime")?;
    if let Some(client) = DaemonClient::try_connect() {
        return client.join_session(
            session_id,
            &protocol::SessionJoinRequest {
                runtime: runtime_name.to_string(),
                role,
                fallback_role,
                capabilities: capabilities.to_vec(),
                name: name.map(ToString::to_string),
                project_dir: project_dir.to_string_lossy().into_owned(),
                persona: persona.map(ToString::to_string),
            },
        );
    }

    let display_name = name.map_or_else(
        || format!("{runtime_name} {role:?}").to_lowercase(),
        ToString::to_string,
    );
    let joined_runtime = resolve_registered_runtime(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent join requires a known runtime, got '{runtime_name}'"
        )))
    })?;
    let agent_session_id =
        agents_service::resolve_known_session_id(joined_runtime, project_dir, None)?;
    let now = utc_now();
    let mut joined_agent_id = None;
    let mut joined_role = role;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    let state = storage::update_state(&layout, |state| {
        joined_role = resolve_join_role(state, role, fallback_role)?;
        let agent_id = apply_join_session(
            state,
            &display_name,
            runtime_name,
            joined_role,
            capabilities,
            agent_session_id.as_deref(),
            &now,
            persona,
        )?;
        joined_agent_id = Some(agent_id);
        Ok(())
    })?;

    let agent_id = joined_agent_id.expect("join_session must record the new agent ID");
    storage::append_log_entry(
        &layout,
        log_agent_joined(&agent_id, joined_role, runtime_name),
        None,
        None,
    )?;

    Ok(state)
}

/// End an active session (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, workers have active tasks,
/// or on storage failures.
pub fn end_session(session_id: &str, actor_id: &str, project_dir: &Path) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.end_session(
            session_id,
            &protocol::SessionEndRequest {
                actor: actor_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut leave_signals = Vec::new();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        leave_signals = prepare_end_session_leave_signals(state, actor_id, &now)?;
        write_prepared_leave_signals(project_dir, &leave_signals, "end session")?;
        apply_end_session(state, actor_id, &now)
    })?;

    append_leave_signal_logs(project_dir, session_id, actor_id, &leave_signals)?;
    storage::append_log_entry(
        &layout,
        log_session_ended(),
        Some(actor_id),
        None,
    )?;
    storage::deregister_active(&layout)?;

    Ok(())
}

/// Assign or change the role of an agent (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the agent is not found.
pub fn assign_role(
    session_id: &str,
    agent_id: &str,
    role: SessionRole,
    reason: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.assign_role(
            session_id,
            agent_id,
            &protocol::RoleChangeRequest {
                actor: actor_id.to_string(),
                role,
                reason: reason.map(ToString::to_string),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut from_role = SessionRole::Worker;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        from_role = apply_assign_role(state, agent_id, role, actor_id, &now)?;
        Ok(())
    })?;

    storage::append_log_entry(
        &layout,
        log_role_changed(agent_id, from_role, role),
        Some(actor_id),
        reason,
    )?;

    Ok(())
}

/// Remove an agent from a session (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the agent is not found.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.remove_agent(
            session_id,
            agent_id,
            &protocol::AgentRemoveRequest {
                actor: actor_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut leave_signal = None;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        leave_signal = prepare_remove_agent_leave_signal(state, agent_id, actor_id, &now)?;
        if let Some(ref signal) = leave_signal {
            write_prepared_leave_signals(project_dir, slice::from_ref(signal), "remove agent")?;
        }
        apply_remove_agent(state, agent_id, actor_id, &now)
    })?;

    if let Some(ref signal) = leave_signal {
        append_leave_signal_logs(project_dir, session_id, actor_id, slice::from_ref(signal))?;
    }
    storage::append_log_entry(
        &layout,
        log_agent_removed(agent_id),
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// Transfer leadership to another agent.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the target is not found.
pub fn transfer_leader(
    session_id: &str,
    new_leader_id: &str,
    reason: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.transfer_leader(
            session_id,
            &protocol::LeaderTransferRequest {
                actor: actor_id.to_string(),
                new_leader_id: new_leader_id.to_string(),
                reason: reason.map(ToString::to_string),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut transfer = None;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        transfer = Some(apply_transfer_leader(
            state,
            new_leader_id,
            actor_id,
            reason,
            &now,
        )?);
        Ok(())
    })?;

    let transfer = transfer.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "leader transfer did not persist state".to_string(),
        ))
    })?;

    if let Some(request) = transfer.pending_request {
        storage::append_log_entry(
            &layout,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id,
                to: request.new_leader_id,
            },
            Some(actor_id),
            request.reason.as_deref(),
        )?;
        return Ok(());
    }

    append_leader_transfer_logs(
        project_dir,
        session_id,
        actor_id,
        transfer.outcome.as_ref().ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "leader transfer did not persist outcome".to_string(),
            ))
        })?,
    )
}

/// Mark the calling agent as disconnected and unassign its tasks.
///
/// When the current leader leaves gracefully, the session either promotes the
/// highest-priority successor or falls back to a leaderless degraded state.
///
/// # Errors
/// Returns `CliError` on storage failures or if the agent is already inactive.
pub fn leave_session(session_id: &str, agent_id: &str, project_dir: &Path) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.leave_session(
            session_id,
            &protocol::SessionLeaveRequest {
                agent_id: agent_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    storage::update_state(&layout, |state| {
        apply_leave_session(state, agent_id, &now)
    })?;

    storage::append_log_entry(
        &layout,
        SessionTransition::AgentLeft {
            agent_id: agent_id.to_string(),
        },
        Some(agent_id),
        None,
    )?;

    Ok(())
}

/// Update a session title.
///
/// # Errors
/// Returns `CliError` if the session cannot be found or persisted.
pub fn update_session_title(
    session_id: &str,
    title: &str,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        return client.update_session_title(
            session_id,
            &protocol::SessionTitleRequest {
                title: title.to_string(),
            },
        );
    }

    let project = resolve_session_project_dir(session_id, project_dir)?;
    let now = utc_now();
    let layout = storage::layout_from_project_dir(&project, session_id)?;
    storage::update_state(&layout, |state| {
        apply_update_session_title(state, title, &now)
    })
}

pub(crate) fn apply_leave_session(
    state: &mut SessionState,
    agent_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    let departing_leader = state.leader_id.as_deref() == Some(agent_id);
    if !departing_leader {
        require_removable_agent(state, agent_id)?;
    }

    let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if !agent.status.is_alive() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is already {}",
            agent_status_label(agent.status)
        ))
        .into());
    }

    agent.status = AgentStatus::Disconnected;
    now.clone_into(&mut agent.updated_at);
    agent.last_activity_at = Some(now.to_string());
    agent.current_task_id = None;

    release_agent_tasks(state, agent_id, now);

    clear_pending_leader_transfer(state, agent_id);
    if departing_leader {
        super::promote_or_degrade(state, now);
    }
    refresh_session(state, now);
    Ok(())
}

pub(crate) fn apply_update_session_title(
    state: &mut SessionState,
    title: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    state.title.clear();
    state.title.push_str(title);
    refresh_session(state, now);
    Ok(())
}
