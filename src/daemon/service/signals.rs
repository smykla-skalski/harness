use super::signals_timeout::warn_active_signal_delivery_timeout;
use super::wake_route::{WakeDispatch, WakeRoute, log_wake_attempt, wake_route_for_registration};
use super::{
    ACTIVE_SIGNAL_ACK_POLL_INTERVAL, ACTIVE_SIGNAL_ACK_TIMEOUT, AckResult, AgentRegistration,
    AgentTuiManagerHandle, CliError, CliErrorKind, Duration, Instant, ManagedTuiWake, Path,
    PathBuf, SessionDetail, SessionState, SignalAck, SignalCoords, SignalSendRequest,
    acknowledged_signal_record, agents_runtime, broadcast_session_snapshot, build_log_entry,
    build_signal_ack, effective_project_dir, index, pending_signal_record,
    project_dir_for_db_session, record_signal_ack, refresh_signal_index_for_db, session_detail,
    session_detail_from_daemon_db, session_not_found, session_service, thread, utc_now,
};
use crate::daemon::agent_acp::AcpWakePrompt;
use crate::daemon::protocol::CodexSteerRequest;
use tokio::sync::broadcast;

mod tui_identity;

pub(crate) use tui_identity::managed_tui_id_for_registration;

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
            .and_then(managed_tui_id_for_registration)
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
        let actively_delivered = attempt_active_signal_delivery(
            &SignalCoords {
                session_id,
                agent_id: &request.agent_id,
                signal: &signal,
                runtime,
                project_dir: &project_dir,
                signal_session_id,
            },
            Some(db),
            managed_tui_wake(target_tui_id.as_deref(), agent_tui_manager),
        );
        if !actively_delivered {
            db.merge_signal_records(
                session_id,
                &[pending_signal_record(
                    session_id,
                    &runtime_name,
                    &request.agent_id,
                    &signal,
                )],
            )?;
        }
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
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
    coords: &SignalCoords<'_>,
    db: Option<&super::db::DaemonDb>,
    managed_tui: Option<ManagedTuiWake<'_>>,
) -> bool {
    let Some(managed_tui) = managed_tui else {
        return false;
    };
    let ack_timeout = managed_tui
        .manager
        .ack_timeout_override()
        .unwrap_or(ACTIVE_SIGNAL_ACK_TIMEOUT);

    let Some(woke_tui) =
        handled_active_signal_wake_result(coords, wake_tui_for_signal(&managed_tui, coords.signal))
    else {
        return false;
    };

    if woke_tui {
        return process_active_signal_ack(coords, db, ack_timeout);
    }
    false
}

pub(crate) fn wake_tui_for_signal(
    managed_tui: &ManagedTuiWake<'_>,
    signal: &agents_runtime::signal::Signal,
) -> Result<bool, CliError> {
    let prompt = build_active_signal_prompt(signal);
    managed_tui.manager.prompt_tui(managed_tui.tui_id, &prompt)
}

pub(crate) fn handled_active_signal_wake_result(
    coords: &SignalCoords<'_>,
    wake_result: Result<bool, CliError>,
) -> Option<bool> {
    match wake_result {
        Ok(woke_tui) => Some(woke_tui),
        Err(error) => {
            warn_active_signal_wake_failure(coords, &error);
            None
        }
    }
}

pub(crate) fn process_active_signal_ack(
    coords: &SignalCoords<'_>,
    db: Option<&super::db::DaemonDb>,
    ack_timeout: Duration,
) -> bool {
    let Some(ack) = handled_active_signal_ack_wait_result(
        coords,
        wait_for_signal_ack(
            coords.runtime,
            coords.project_dir,
            coords.signal_session_id,
            &coords.signal.signal_id,
            ack_timeout,
        ),
        ack_timeout,
    ) else {
        return false;
    };

    record_active_signal_ack(coords, db, &ack)
}

pub(crate) fn handled_active_signal_ack_wait_result(
    coords: &SignalCoords<'_>,
    ack_result: Result<Option<SignalAck>, CliError>,
    ack_timeout: Duration,
) -> Option<SignalAck> {
    match ack_result {
        Ok(Some(ack)) => Some(ack),
        Ok(None) => {
            warn_active_signal_delivery_timeout(
                coords.session_id,
                coords.agent_id,
                &coords.signal.signal_id,
                ack_timeout,
            );
            None
        }
        Err(error) => {
            warn_active_signal_ack_wait_failure(coords, &error);
            None
        }
    }
}

pub(crate) fn record_active_signal_ack(
    coords: &SignalCoords<'_>,
    db: Option<&super::db::DaemonDb>,
    ack: &SignalAck,
) -> bool {
    let result = record_signal_ack_and_broadcast(
        coords.session_id,
        coords.agent_id,
        &coords.signal.signal_id,
        ack.result,
        coords.project_dir,
        db,
        None,
    );
    match result {
        Ok(()) => true,
        Err(error) => {
            warn_active_signal_ack_record_failure(coords, &error);
            false
        }
    }
}

pub(crate) fn record_signal_ack_and_broadcast(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&super::db::DaemonDb>,
    sender: Option<&broadcast::Sender<super::StreamEvent>>,
) -> Result<(), CliError> {
    record_signal_ack(session_id, agent_id, signal_id, result, project_dir, db)?;
    if let Some(sender) = sender {
        broadcast_session_snapshot(sender, session_id, db);
    }
    Ok(())
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
    timeout: Duration,
) -> Result<Option<SignalAck>, CliError> {
    let deadline = Instant::now() + timeout;
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

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_wake_failure(coords: &SignalCoords<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = coords.session_id,
        agent_id = coords.agent_id,
        signal_id = %coords.signal.signal_id,
        "failed to wake managed TUI for active signal delivery"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_ack_wait_failure(coords: &SignalCoords<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = coords.session_id,
        agent_id = coords.agent_id,
        signal_id = %coords.signal.signal_id,
        "failed while waiting for active signal acknowledgment"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
pub(crate) fn warn_active_signal_ack_record_failure(coords: &SignalCoords<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = coords.session_id,
        agent_id = coords.agent_id,
        signal_id = %coords.signal.signal_id,
        "failed to record actively delivered signal acknowledgment"
    );
}

/// Best-effort active wake for `Started` task-drop effects.
///
/// For each `TaskDropEffect::Started`, look up the worker's TUI id and try to
/// prompt the managed runtime so it picks the new task up immediately rather
/// than on its next signal-dir scan. Failures are logged and ignored: the
/// pending signal record was already merged by the caller, so the worker will
/// still pick the signal up via its periodic poll.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn try_wake_started_workers(
    state: &SessionState,
    effects: &[session_service::TaskDropEffect],
    session_id: &str,
    project_dir: &Path,
    db: Option<&super::db::DaemonDb>,
    dispatch: WakeDispatch<'_>,
) {
    for effect in effects {
        let session_service::TaskDropEffect::Started(record) = effect else {
            continue;
        };
        let Some(runtime) = agents_runtime::runtime_for_name(&record.runtime) else {
            tracing::warn!(session_id, agent_id = %record.agent_id, runtime = %record.runtime, signal_id = %record.signal.signal_id, "task wake skipped: unknown runtime");
            continue;
        };
        let registration = state.agents.get(&record.agent_id);
        let route = wake_route_for_registration(registration, dispatch);
        log_wake_attempt(session_id, record.as_ref(), &route);
        match route {
            WakeRoute::Tui { tui_id, manager } => {
                let _ = attempt_active_signal_delivery(
                    &SignalCoords {
                        session_id,
                        agent_id: &record.agent_id,
                        signal: &record.signal,
                        runtime,
                        project_dir,
                        signal_session_id: &record.signal_session_id,
                    },
                    db,
                    Some(ManagedTuiWake { tui_id, manager }),
                );
            }
            WakeRoute::Acp { acp_id, manager } => {
                manager.dispatch_wake_prompt(
                    runtime,
                    AcpWakePrompt {
                        acp_id: acp_id.to_string(),
                        orchestration_session_id: session_id.to_string(),
                        signal_session_id: record.signal_session_id.clone(),
                        signal_dir: runtime.signal_dir(project_dir, &record.signal_session_id),
                        project_dir: project_dir.to_path_buf(),
                        prompt: build_active_signal_prompt(&record.signal),
                        signal_id: record.signal.signal_id.clone(),
                        agent_id: record.agent_id.clone(),
                    },
                );
            }
            WakeRoute::Codex { run_id, controller } => {
                let request = CodexSteerRequest {
                    prompt: build_active_signal_prompt(&record.signal),
                };
                if let Err(error) = controller.steer(run_id, &request) {
                    tracing::warn!(session_id, agent_id = %record.agent_id, signal_id = %record.signal.signal_id, %error, "wake skipped: codex steer failed");
                }
            }
            WakeRoute::None { reason } => {
                tracing::warn!(session_id, agent_id = %record.agent_id, signal_id = %record.signal.signal_id, reason = %reason, "wake skipped: signal stays file-only");
            }
        }
    }
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
        if let Some(signal) = db.load_signals(session_id)?.into_iter().find(|record| {
            record.agent_id == request.agent_id && record.signal.signal_id == request.signal_id
        }) {
            let ack_agent = db
                .load_session_state(session_id)?
                .and_then(|state| {
                    state
                        .agents
                        .get(&request.agent_id)
                        .and_then(|agent| agent.agent_session_id.clone())
                })
                .unwrap_or_else(|| session_id.to_string());
            db.merge_signal_records(
                session_id,
                &[acknowledged_signal_record(
                    &signal.runtime,
                    &request.agent_id,
                    &signal.signal,
                    &build_signal_ack(
                        session_id,
                        &signal.signal.signal_id,
                        &utc_now(),
                        AckResult::Rejected,
                        &ack_agent,
                        Some(format!("cancelled by {}", request.actor)),
                    ),
                )],
            )?;
        } else {
            refresh_signal_index_for_db(db, session_id)?;
        }
        db.bump_change(session_id)?;
        db.bump_change("global")?;
    }
    session_detail(session_id, db)
}
