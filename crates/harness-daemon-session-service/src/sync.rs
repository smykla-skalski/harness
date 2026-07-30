use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use harness_agents::runtime as agents_runtime;
use harness_agents::runtime::signal::{AckResult, Signal, SignalAck};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::index;
use harness_session::service as session_service;
use harness_session::wire::{SessionDetail, SignalCancelRequest, SignalSendRequest};
use harness_workspace::workspace::utc_now;

use crate::persistence::{
    acknowledged_signal_record, build_log_entry, build_signal_ack, effective_project_dir,
    pending_signal_record, project_dir_for_db_session, record_signal_ack, refresh_signal_index,
    session_detail, session_not_found,
};
use crate::ports::{SignalStorage, SignalWake};
use crate::timeout::warn_active_signal_delivery_timeout;
pub use crate::tui_identity::managed_tui_id_for_registration;

pub(crate) const ACTIVE_SIGNAL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
pub(crate) const ACTIVE_SIGNAL_ACK_POLL_INTERVAL: Duration = Duration::from_millis(50);

pub(crate) struct SignalCoords<'a> {
    pub(crate) session_id: &'a str,
    pub(crate) agent_id: &'a str,
    pub(crate) signal: &'a Signal,
    pub(crate) runtime: &'a dyn agents_runtime::AgentRuntime,
    pub(crate) project_dir: &'a Path,
    pub(crate) signal_session_id: &'a str,
}

pub(crate) struct ManagedSignalWake<'a> {
    pub(crate) managed_id: &'a str,
    pub(crate) transport: &'a dyn SignalWake,
}

/// Send a signal through the shared session service.
///
/// Signal files are always written to disk for runtime pickup, even in
/// the DB-direct path, because agent runtimes poll the filesystem.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or signal delivery setup fails.
pub fn send_signal<S: SignalStorage>(
    session_id: &str,
    request: &SignalSendRequest,
    storage: Option<&S>,
    wake: Option<&dyn SignalWake>,
) -> Result<SessionDetail, CliError> {
    if let Some(storage) = storage
        && let Some(mut state) = storage.load_session_state_for_mutation(session_id)?
    {
        // DB-direct: apply state mutation to SQLite, then write signal file.
        let now = utc_now();
        let project_dir = project_dir_for_db_session(storage, session_id)?;
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
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;

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

        storage.append_log_entry(&build_log_entry(
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
            session_id,
            &request.agent_id,
            &signal,
            runtime,
            &project_dir,
            signal_session_id,
            Some(storage),
            target_tui_id.as_deref(),
            wake,
        );
        if !actively_delivered {
            storage.merge_signal_records(
                session_id,
                &[pending_signal_record(
                    session_id,
                    &runtime_name,
                    &request.agent_id,
                    &signal,
                )],
            )?;
        }
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
        return storage.session_detail(session_id);
    }

    // File-based fallback
    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let _ = session_service::send_signal_local(
        session_id,
        &request.agent_id,
        &request.command,
        &request.message,
        request.action_hint.as_deref(),
        &request.actor,
        &project_dir,
    )?;
    session_detail(session_id, storage)
}

pub(crate) fn managed_signal_wake<'a>(
    managed_id: Option<&'a str>,
    transport: Option<&'a dyn SignalWake>,
) -> Option<ManagedSignalWake<'a>> {
    Some(ManagedSignalWake {
        managed_id: managed_id?,
        transport: transport?,
    })
}

/// Try an immediate managed-runtime wake and persist any acknowledgment.
#[must_use]
#[expect(
    clippy::too_many_arguments,
    reason = "the public port keeps signal coordinates explicit for daemon adapters"
)]
pub fn attempt_active_signal_delivery<S: SignalStorage>(
    session_id: &str,
    agent_id: &str,
    signal: &Signal,
    runtime: &dyn agents_runtime::AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    storage: Option<&S>,
    managed_id: Option<&str>,
    wake: Option<&dyn SignalWake>,
) -> bool {
    attempt_active_signal_delivery_with_coords(
        &SignalCoords {
            session_id,
            agent_id,
            signal,
            runtime,
            project_dir,
            signal_session_id,
        },
        storage,
        managed_signal_wake(managed_id, wake),
    )
}

fn attempt_active_signal_delivery_with_coords<S: SignalStorage>(
    coords: &SignalCoords<'_>,
    storage: Option<&S>,
    managed_wake: Option<ManagedSignalWake<'_>>,
) -> bool {
    let Some(managed_wake) = managed_wake else {
        return false;
    };
    let ack_timeout = managed_wake
        .transport
        .ack_timeout_override()
        .unwrap_or(ACTIVE_SIGNAL_ACK_TIMEOUT);

    let Some(woke_runtime) = handled_active_signal_wake_result(
        coords,
        wake_runtime_for_signal(&managed_wake, coords.signal),
    ) else {
        return false;
    };

    if woke_runtime {
        return process_active_signal_ack(coords, storage, ack_timeout);
    }
    false
}

pub(crate) fn wake_runtime_for_signal(
    managed_wake: &ManagedSignalWake<'_>,
    signal: &agents_runtime::signal::Signal,
) -> Result<bool, CliError> {
    let prompt = build_active_signal_prompt(signal);
    managed_wake
        .transport
        .prompt(managed_wake.managed_id, &prompt)
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

pub(crate) fn process_active_signal_ack<S: SignalStorage>(
    coords: &SignalCoords<'_>,
    storage: Option<&S>,
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

    record_active_signal_ack(coords, storage, &ack)
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

pub(crate) fn record_active_signal_ack<S: SignalStorage>(
    coords: &SignalCoords<'_>,
    storage: Option<&S>,
    ack: &SignalAck,
) -> bool {
    let result = record_signal_ack(
        coords.session_id,
        coords.agent_id,
        &coords.signal.signal_id,
        ack.result,
        coords.project_dir,
        storage,
    );
    match result {
        Ok(()) => true,
        Err(error) => {
            warn_active_signal_ack_record_failure(coords, &error);
            false
        }
    }
}

#[must_use]
pub fn build_active_signal_prompt(signal: &agents_runtime::signal::Signal) -> String {
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

/// Cancel a pending signal by writing a rejected acknowledgment.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the signal is not
/// pending, or ack persistence fails.
pub fn cancel_signal<S: SignalStorage>(
    session_id: &str,
    request: &SignalCancelRequest,
    storage: Option<&S>,
) -> Result<SessionDetail, CliError> {
    let project_dir = if let Some(storage) = storage
        && let Some(dir) = storage.project_dir_for_session(session_id)?
    {
        PathBuf::from(dir)
    } else {
        let resolved = index::resolve_session(session_id)?;
        effective_project_dir(&resolved).to_path_buf()
    };

    session_service::cancel_signal_local(
        session_id,
        &request.agent_id,
        &request.signal_id,
        &request.actor,
        &project_dir,
    )?;

    if let Some(storage) = storage {
        if let Some(signal) = storage
            .load_signals(session_id)?
            .into_iter()
            .find(|record| {
                record.agent_id == request.agent_id && record.signal.signal_id == request.signal_id
            })
        {
            let ack_agent = storage
                .load_session_state(session_id)?
                .and_then(|state| {
                    state
                        .agents
                        .get(&request.agent_id)
                        .and_then(|agent| agent.agent_session_id.clone())
                })
                .unwrap_or_else(|| session_id.to_string());
            storage.merge_signal_records(
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
            refresh_signal_index(storage, session_id)?;
        }
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
    }
    session_detail(session_id, storage)
}
