use super::*;

/// Send a signal through the shared session service.
///
/// Signal files are always written to disk for runtime pickup, even in
/// the DB-direct path, because agent runtimes poll the filesystem.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or signal delivery setup fails.
pub fn send_signal(
    session_id: &str,
    request: &SignalSendRequest,
    db: Option<&super::db::DaemonDb>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        // DB-direct: apply state mutation to SQLite, then write signal file.
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let (runtime_name, target_agent_session_id) = session_service::apply_send_signal_state(
            &mut state,
            &request.agent_id,
            &request.actor,
            &now,
        )?;
        let target_tui_id = state
            .agents
            .get(&request.agent_id)
            .and_then(agent_tui_id_for_registration)
            .map(ToString::to_string);
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;

        // Write signal file for runtime pickup (always file-based).
        let signal = session_service::build_signal(
            &request.actor,
            &request.command,
            &request.message,
            request.action_hint.as_deref(),
            session_id,
            &request.agent_id,
            &now,
        );
        let runtime = agents_runtime::runtime_for_name(&runtime_name).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "unknown runtime '{runtime_name}'"
            )))
        })?;
        let signal_session_id = target_agent_session_id.as_deref().unwrap_or(session_id);
        runtime.write_signal(&project_dir, signal_session_id, &signal)?;

        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &signal.signal_id,
                &request.agent_id,
                &request.command,
            ),
            Some(&request.actor),
            None,
        ))?;
        attempt_active_signal_delivery(
            &ActiveSignalDelivery {
                session_id,
                agent_id: &request.agent_id,
                signal: &signal,
                runtime,
                project_dir: &project_dir,
                signal_session_id,
                db: Some(db),
            },
            managed_tui_wake(target_tui_id.as_deref(), agent_tui_manager),
        );
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    // File-based fallback
    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let _ = session_service::send_signal(
        session_id,
        &request.agent_id,
        &request.command,
        &request.message,
        request.action_hint.as_deref(),
        &request.actor,
        &project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

pub(crate) fn managed_tui_wake<'a>(
    tui_id: Option<&'a str>,
    agent_tui_manager: Option<&'a AgentTuiManagerHandle>,
) -> Option<ManagedTuiWake<'a>> {
    Some(ManagedTuiWake {
        tui_id: tui_id?,
        manager: agent_tui_manager?,
    })
}

pub(crate) fn attempt_active_signal_delivery(
    delivery: &ActiveSignalDelivery<'_>,
    managed_tui: Option<ManagedTuiWake<'_>>,
) {
    let Some(managed_tui) = managed_tui else {
        return;
    };

    let Some(woke_tui) = handled_active_signal_wake_result(
        delivery,
        wake_tui_for_signal(&managed_tui, delivery.signal),
    ) else {
        return;
    };

    if woke_tui {
        process_active_signal_ack(delivery);
    }
}

pub(crate) fn wake_tui_for_signal(
    managed_tui: &ManagedTuiWake<'_>,
    signal: &agents_runtime::signal::Signal,
) -> Result<bool, CliError> {
    let prompt = build_active_signal_prompt(signal);
    managed_tui.manager.prompt_tui(managed_tui.tui_id, &prompt)
}

pub(crate) fn handled_active_signal_wake_result(
    delivery: &ActiveSignalDelivery<'_>,
    wake_result: Result<bool, CliError>,
) -> Option<bool> {
    match wake_result {
        Ok(woke_tui) => Some(woke_tui),
        Err(error) => {
            warn_active_signal_wake_failure(delivery, &error);
            None
        }
    }
}

pub(crate) fn process_active_signal_ack(delivery: &ActiveSignalDelivery<'_>) {
    let Some(ack) = handled_active_signal_ack_wait_result(
        delivery,
        wait_for_signal_ack(
            delivery.runtime,
            delivery.project_dir,
            delivery.signal_session_id,
            &delivery.signal.signal_id,
        ),
    ) else {
        return;
    };

    record_active_signal_ack(delivery, &ack);
}

pub(crate) fn handled_active_signal_ack_wait_result(
    delivery: &ActiveSignalDelivery<'_>,
    ack_result: Result<Option<SignalAck>, CliError>,
) -> Option<SignalAck> {
    match ack_result {
        Ok(Some(ack)) => Some(ack),
        Ok(None) => {
            warn_active_signal_delivery_timeout(
                delivery.session_id,
                delivery.agent_id,
                &delivery.signal.signal_id,
            );
            None
        }
        Err(error) => {
            warn_active_signal_ack_wait_failure(delivery, &error);
            None
        }
    }
}

pub(crate) fn record_active_signal_ack(delivery: &ActiveSignalDelivery<'_>, ack: &SignalAck) {
    let Err(error) = record_signal_ack(
        delivery.session_id,
        delivery.agent_id,
        &delivery.signal.signal_id,
        ack.result,
        delivery.project_dir,
        delivery.db,
    ) else {
        return;
    };

    warn_active_signal_ack_record_failure(delivery, &error);
}

pub(crate) fn build_active_signal_prompt(signal: &agents_runtime::signal::Signal) -> String {
    match signal.payload.action_hint.as_deref() {
        Some(action_hint) => format!(
            "[Harness signal] {}: {} ({action_hint})",
            signal.command, signal.payload.message
        ),
        None => format!(
            "[Harness signal] {}: {}",
            signal.command, signal.payload.message
        ),
    }
}

pub(crate) fn wait_for_signal_ack(
    runtime: &dyn agents_runtime::AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    signal_id: &str,
) -> Result<Option<SignalAck>, CliError> {
    let deadline = Instant::now() + ACTIVE_SIGNAL_ACK_TIMEOUT;
    loop {
        if let Some(ack) = runtime
            .read_acknowledgments(project_dir, signal_session_id)?
            .into_iter()
            .find(|ack| ack.signal_id == signal_id)
        {
            return Ok(Some(ack));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        thread::sleep(ACTIVE_SIGNAL_ACK_POLL_INTERVAL);
    }
}

pub(crate) fn warn_active_signal_delivery_timeout(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
) {
    state::append_event_best_effort(
        "warn",
        &active_signal_delivery_timeout_message(session_id, agent_id, signal_id),
    );
    log_active_signal_delivery_timeout(session_id, agent_id, signal_id);
}

pub(crate) fn active_signal_delivery_timeout_message(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
) -> String {
    format!(
        "session '{session_id}' signal '{signal_id}' to agent '{agent_id}' stayed pending after active TUI wake-up for {} ms",
        ACTIVE_SIGNAL_ACK_TIMEOUT.as_millis()
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_wake_failure(
    delivery: &ActiveSignalDelivery<'_>,
    error: &CliError,
) {
    tracing::warn!(
        %error,
        session_id = delivery.session_id,
        agent_id = delivery.agent_id,
        signal_id = %delivery.signal.signal_id,
        "failed to wake managed TUI for active signal delivery"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_ack_wait_failure(
    delivery: &ActiveSignalDelivery<'_>,
    error: &CliError,
) {
    tracing::warn!(
        %error,
        session_id = delivery.session_id,
        agent_id = delivery.agent_id,
        signal_id = %delivery.signal.signal_id,
        "failed while waiting for active signal acknowledgment"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_ack_record_failure(
    delivery: &ActiveSignalDelivery<'_>,
    error: &CliError,
) {
    tracing::warn!(
        %error,
        session_id = delivery.session_id,
        agent_id = delivery.agent_id,
        signal_id = %delivery.signal.signal_id,
        "failed to record actively delivered signal acknowledgment"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn log_active_signal_delivery_timeout(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
) {
    tracing::warn!(
        session_id,
        agent_id,
        signal_id,
        timeout_ms = ACTIVE_SIGNAL_ACK_TIMEOUT.as_millis(),
        "active TUI signal delivery timed out"
    );
}

pub(crate) fn agent_tui_id_for_registration(agent: &AgentRegistration) -> Option<&str> {
    agent.capabilities.iter().find_map(|capability| {
        capability
            .strip_prefix("agent-tui:")
            .filter(|value| !value.trim().is_empty())
    })
}

/// Cancel a pending signal by writing a rejected acknowledgment.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the signal is not
/// pending, or ack persistence fails.
pub fn cancel_signal(
    session_id: &str,
    request: &super::protocol::SignalCancelRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = if let Some(db) = db
        && let Some(dir) = db.project_dir_for_session(session_id)?
    {
        PathBuf::from(dir)
    } else {
        let resolved = index::resolve_session(session_id)?;
        effective_project_dir(&resolved).to_path_buf()
    };

    session_service::cancel_signal(
        session_id,
        &request.agent_id,
        &request.signal_id,
        &request.actor,
        &project_dir,
    )?;

    if let Some(db) = db {
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
    } else {
        sync_after_mutation(db, session_id);
    }
    session_detail(session_id, db)
}
