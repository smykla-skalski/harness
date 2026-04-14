use super::*;

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
    let runtime_name = runtime_name.ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(
            "session start requires --runtime for leader session tracking".to_string(),
        ))
    })?;
    ensure_known_runtime(runtime_name, "session start requires a known runtime")?;

    if let Some(client) = DaemonClient::try_connect() {
        return client.start_session(&protocol::SessionStartRequest {
            title: title.to_string(),
            context: context.to_string(),
            runtime: runtime_name.to_string(),
            session_id: session_id.map(ToString::to_string),
            project_dir: project_dir.to_string_lossy().into_owned(),
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
    )?;
    let leader_id = state
        .leader_id
        .as_deref()
        .expect("new session always has a leader");

    storage::register_active(project_dir, &state.session_id)?;
    let _ = storage::record_project_origin(project_dir);
    storage::append_log_entry(
        project_dir,
        &state.session_id,
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
    ensure_known_runtime(runtime_name, "agent join requires a known runtime")?;
    if let Some(client) = DaemonClient::try_connect() {
        return client.join_session(
            session_id,
            &protocol::SessionJoinRequest {
                runtime: runtime_name.to_string(),
                role,
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

    let state = storage::update_state(project_dir, session_id, |state| {
        let agent_id = apply_join_session(
            state,
            &display_name,
            runtime_name,
            role,
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
        project_dir,
        session_id,
        log_agent_joined(&agent_id, role, runtime_name),
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

    storage::update_state(project_dir, session_id, |state| {
        leave_signals = prepare_end_session_leave_signals(state, actor_id, &now)?;
        write_prepared_leave_signals(project_dir, &leave_signals, "end session")?;
        apply_end_session(state, actor_id, &now)
    })?;

    append_leave_signal_logs(project_dir, session_id, actor_id, &leave_signals)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        log_session_ended(),
        Some(actor_id),
        None,
    )?;
    storage::deregister_active(project_dir, session_id)?;

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

    storage::update_state(project_dir, session_id, |state| {
        from_role = apply_assign_role(state, agent_id, role, actor_id, &now)?;
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
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

    storage::update_state(project_dir, session_id, |state| {
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
        project_dir,
        session_id,
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

    storage::update_state(project_dir, session_id, |state| {
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
            project_dir,
            session_id,
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

/// Create a work item in the session.
///
/// # Errors

/// Mark the calling agent as disconnected and unassign its tasks.
///
/// Leaders cannot leave; they must transfer leadership first. This is a
/// voluntary, graceful exit - the liveness sync handles involuntary exits.
///
/// # Errors
/// Returns `CliError` on storage failures or if the agent is the leader.
pub fn leave_session(session_id: &str, agent_id: &str, project_dir: &Path) -> Result<(), CliError> {
    let now = utc_now();
    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_removable_agent(state, agent_id)?;

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
        agent.last_activity_at = Some(now.clone());
        agent.current_task_id = None;

        release_agent_tasks(state, agent_id, &now);

        clear_pending_leader_transfer(state, agent_id);
        refresh_session(state, &now);
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::AgentLeft {
            agent_id: agent_id.to_string(),
        },
        Some(agent_id),
        None,
    )?;

    Ok(())
}
