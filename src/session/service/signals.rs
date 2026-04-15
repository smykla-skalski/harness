use super::{
    AckResult, CliError, CliErrorKind, DaemonClient, Path, ResolvedRuntimeSessionAgent,
    SessionSignalRecord, SessionSignalStatus, SessionTransition, SignalAck,
    apply_send_signal_state, apply_signal_ack_result, build_signal, load_signal_record_for_agent,
    load_state_or_err, log_signal_acknowledged, log_signal_sent, log_task_assigned,
    normalize_signal_ack_result, protocol, read_pending_signals, reconcile_expired_pending_signals,
    refresh_session, resolve_runtime_session_via_daemon, runtime, runtime_session_matches_agent,
    signal_context_root, signal_dirs_for_agent_in_context_root, signal_records_for_dirs, storage,
    utc_now,
    write_signal_ack,
};

/// Send a file-backed signal to a running agent session.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target agent is not
/// active, or the runtime adapter is unknown.
pub fn send_signal(
    session_id: &str,
    agent_id: &str,
    command: &str,
    message: &str,
    action_hint: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<SessionSignalRecord, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.send_signal(
            session_id,
            &protocol::SignalSendRequest {
                actor: actor_id.to_string(),
                agent_id: agent_id.to_string(),
                command: command.to_string(),
                message: message.to_string(),
                action_hint: action_hint.map(ToString::to_string),
            },
        )?;
        return detail
            .signals
            .into_iter()
            .find(|signal| signal.signal.command == command && signal.agent_id == agent_id)
            .ok_or_else(|| {
                CliErrorKind::workflow_io(
                    "daemon sent signal but returned no matching signal record",
                )
                .into()
            });
    }

    let now = utc_now();
    let mut runtime_name = String::new();
    let mut target_agent_session_id = None;

    storage::update_state(project_dir, session_id, |state| {
        let (name, session_id) = apply_send_signal_state(state, agent_id, actor_id, &now)?;
        runtime_name = name;
        target_agent_session_id = session_id;
        Ok(())
    })?;

    let runtime = runtime::runtime_for_name(&runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{runtime_name}'"
        )))
    })?;

    let signal = build_signal(
        actor_id,
        command,
        message,
        action_hint,
        session_id,
        agent_id,
        &now,
    );

    let signal_session_id = target_agent_session_id.as_deref().unwrap_or(session_id);
    runtime.write_signal(project_dir, signal_session_id, &signal)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        log_signal_sent(&signal.signal_id, agent_id, command),
        Some(actor_id),
        None,
    )?;

    Ok(SessionSignalRecord {
        runtime: runtime_name,
        agent_id: agent_id.to_string(),
        session_id: session_id.to_string(),
        status: SessionSignalStatus::Pending,
        signal,
        acknowledgment: None,
    })
}

/// Cancel a pending signal by writing a rejected acknowledgment and moving the
/// signal file out of pending.
///
/// Signal delivery is passive: the runtime's agent hook cycles read pending
/// signals and write acks. When a user cancels from the monitor, we write the
/// rejected ack directly and move the file so the next hook cycle does not
/// deliver the signal, and the monitor shows a consistent state on its next
/// snapshot.
///
/// # Errors
/// Returns `CliError` when the session/agent cannot be resolved, the signal
/// file cannot be found, or ack persistence fails.
pub fn cancel_signal(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        client.cancel_signal(
            session_id,
            &protocol::SignalCancelRequest {
                actor: actor_id.to_string(),
                agent_id: agent_id.to_string(),
                signal_id: signal_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let state = load_state_or_err(session_id, project_dir)?;
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found in session '{session_id}'"
        )))
    })?;
    let runtime = runtime::runtime_for_name(&agent.runtime).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{}'",
            agent.runtime
        )))
    })?;

    let now = utc_now();
    let signal_session_id = agent.agent_session_id.as_deref().unwrap_or(session_id);
    let signal_dir = runtime.signal_dir(project_dir, signal_session_id);

    let pending = read_pending_signals(&signal_dir)?;
    let matched = pending.iter().any(|signal| signal.signal_id == signal_id);
    if !matched {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "signal '{signal_id}' is not pending for agent '{agent_id}'"
        ))));
    }

    let ack = SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at: now,
        result: AckResult::Rejected,
        agent: signal_session_id.to_string(),
        session_id: session_id.to_string(),
        details: Some(format!("cancelled by {actor_id}")),
    };
    write_signal_ack(&signal_dir, &ack)?;

    storage::append_log_entry(
        project_dir,
        session_id,
        log_signal_acknowledged(signal_id, agent_id, AckResult::Rejected),
        Some(actor_id),
        None,
    )?;
    Ok(())
}

/// List all signals for a session, optionally narrowed to one agent.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or runtime signal
/// directories cannot be read.
pub fn list_signals(
    session_id: &str,
    agent_filter: Option<&str>,
    project_dir: &Path,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        let mut signals: Vec<SessionSignalRecord> = detail
            .signals
            .into_iter()
            .filter(|signal| agent_filter.is_none_or(|filter| signal.agent_id == filter))
            .collect();
        signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
        return Ok(signals);
    }

    reconcile_expired_pending_signals(session_id, project_dir)?;
    let state = load_state_or_err(session_id, project_dir)?;
    let mut signals = Vec::new();
    let context_root = signal_context_root(project_dir);

    for (agent_id, agent) in state.agents {
        if agent_filter.is_some_and(|filter| filter != agent_id) {
            continue;
        }
        let Some(runtime) = runtime::runtime_for_name(&agent.runtime) else {
            continue;
        };
        let signal_dirs = signal_dirs_for_agent_in_context_root(
            runtime,
            session_id,
            agent.agent_session_id.as_deref(),
            &context_root,
        );
        signals.extend(signal_records_for_dirs(
            &agent.runtime,
            &agent_id,
            session_id,
            &signal_dirs,
        )?);
    }

    signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
    Ok(signals)
}

/// Resolve the orchestration session and agent owning a runtime session ID.
///
/// # Errors
/// Returns `CliError` when the active session registry cannot be read or the
/// runtime session is ambiguous across active sessions.
pub fn resolve_session_agent_for_runtime_session(
    project_dir: &Path,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        return resolve_runtime_session_via_daemon(&client, runtime_name, runtime_session_id);
    }

    let active_session_ids: Vec<_> = storage::load_active_registry_for(project_dir)
        .sessions
        .into_keys()
        .collect();
    let mut matches = Vec::new();

    for session_id in active_session_ids {
        let Some(state) = storage::load_state(project_dir, &session_id)? else {
            continue;
        };
        for (agent_id, agent) in &state.agents {
            if !agent.status.is_alive() || agent.runtime != runtime_name {
                continue;
            }
            if runtime_session_matches_agent(&state.session_id, agent, runtime_session_id) {
                matches.push(ResolvedRuntimeSessionAgent {
                    orchestration_session_id: state.session_id.clone(),
                    agent_id: agent_id.clone(),
                });
            }
        }
    }

    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.into_iter().next()),
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{runtime_session_id}' for runtime '{runtime_name}' maps to multiple orchestration sessions"
        ))
        .into()),
    }
}

/// Persist a signal acknowledgment into the authoritative session audit log.
///
/// # Errors
/// Returns `CliError` if the session log cannot be read or updated.
pub fn record_signal_acknowledgment(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        return client.record_signal_ack(
            session_id,
            &protocol::SignalAckRequest {
                agent_id: agent_id.to_string(),
                signal_id: signal_id.to_string(),
                result,
                project_dir: project_dir.to_string_lossy().into_owned(),
            },
        );
    }

    let already_logged = storage::load_log_entries(project_dir, session_id)?
        .into_iter()
        .any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::SignalAcknowledged { signal_id: ref existing, .. }
                    if existing == signal_id
            )
        });
    if already_logged {
        return Ok(());
    }

    let now = utc_now();
    let signal = load_signal_record_for_agent(session_id, agent_id, signal_id, project_dir)?;
    let result = signal.as_ref().map_or(result, |signal| {
        normalize_signal_ack_result(&signal.signal, result)
    });
    let mut started_task = None;

    storage::update_state(project_dir, session_id, |state| {
        if let Some(signal) = signal.as_ref() {
            started_task = apply_signal_ack_result(state, agent_id, &signal.signal, result, &now);
            refresh_session(state, &now);
        }
        Ok(())
    })?;

    if let Some(task_id) = started_task.as_deref() {
        storage::append_log_entry(
            project_dir,
            session_id,
            log_task_assigned(task_id, agent_id),
            Some(agent_id),
            None,
        )?;
    }

    storage::append_log_entry(
        project_dir,
        session_id,
        log_signal_acknowledged(signal_id, agent_id, result),
        Some(agent_id),
        None,
    )
}
