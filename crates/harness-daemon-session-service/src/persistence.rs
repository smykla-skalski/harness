use std::path::{Path, PathBuf};

use harness_agents::runtime::signal::{AckResult, Signal, SignalAck};
use harness_daemon_snapshot as snapshot;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::index::{self, ResolvedSession};
use harness_session::service as session_service;
use harness_session::types::{
    SessionLogEntry, SessionSignalRecord, SessionSignalStatus, SessionTransition,
};
use harness_session::wire::SessionDetail;
use harness_workspace::workspace::utc_now;

use crate::ports::SignalStorage;

/// Record a signal acknowledgment in canonical storage or the file fallback.
///
/// # Errors
/// Returns an error when the acknowledgment cannot be persisted.
pub fn record_signal_ack<S: SignalStorage>(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    storage: Option<&S>,
) -> Result<(), CliError> {
    let Some(storage) = storage else {
        return record_signal_ack_fallback(session_id, agent_id, signal_id, result, project_dir);
    };
    let Some(mut state) = storage.load_session_state_for_mutation(session_id)? else {
        return record_signal_ack_fallback(session_id, agent_id, signal_id, result, project_dir);
    };

    let already_logged = storage
        .load_session_log(session_id)?
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
    let signal = if let Some(signal) = storage
        .load_signals(session_id)?
        .into_iter()
        .find(|record| record.agent_id == agent_id && record.signal.signal_id == signal_id)
    {
        Some(signal)
    } else {
        session_service::load_signal_record_for_agent_from_state(
            &state,
            agent_id,
            signal_id,
            project_dir,
        )?
    };
    let result = signal.as_ref().map_or(result, |signal| {
        session_service::normalize_signal_ack_result(&signal.signal, result)
    });
    let started_task = if let Some(signal) = signal.as_ref() {
        let started_task = session_service::apply_signal_ack_result(
            &mut state,
            agent_id,
            &signal.signal,
            result,
            &now,
        );
        session_service::refresh_session(&mut state, &now);
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;
        let ack_agent = state
            .agents
            .get(agent_id)
            .and_then(|agent| agent.agent_session_id.as_deref())
            .unwrap_or(session_id);
        let acknowledgment = build_signal_ack(
            session_id,
            &signal.signal.signal_id,
            &now,
            result,
            ack_agent,
            None,
        );
        storage.merge_signal_records(
            session_id,
            &[acknowledged_signal_record(
                &signal.runtime,
                agent_id,
                &signal.signal,
                &acknowledgment,
            )],
        )?;
        started_task
    } else {
        refresh_signal_index(storage, session_id)?;
        None
    };

    if let Some(task_id) = started_task.as_deref() {
        storage.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, agent_id),
            Some(agent_id),
            None,
        ))?;
    }

    storage.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_signal_acknowledged(signal_id, agent_id, result),
        Some(agent_id),
        None,
    ))?;
    storage.bump_change(session_id)?;
    storage.bump_change("global")
}

fn record_signal_ack_fallback(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
) -> Result<(), CliError> {
    session_service::record_signal_acknowledgment(
        session_id,
        agent_id,
        signal_id,
        result,
        project_dir,
    )
}

pub(crate) fn project_dir_for_db_session<S: SignalStorage>(
    storage: &S,
    session_id: &str,
) -> Result<PathBuf, CliError> {
    if let Some(project_dir) = storage.project_dir_for_session(session_id)? {
        return Ok(PathBuf::from(project_dir));
    }

    let resolved = storage
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    Ok(effective_project_dir(&resolved).to_path_buf())
}

pub(crate) fn effective_project_dir(resolved: &ResolvedSession) -> &Path {
    resolved
        .project
        .project_dir
        .as_deref()
        .unwrap_or(&resolved.project.context_root)
}

pub(crate) fn session_not_found(session_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("harness session '{session_id}' not found")).into()
}

pub(crate) fn build_log_entry(
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> SessionLogEntry {
    SessionLogEntry {
        sequence: 0,
        recorded_at: utc_now(),
        session_id: session_id.to_string(),
        transition,
        actor_id: actor_id.map(ToString::to_string),
        reason: reason.map(ToString::to_string),
    }
}

pub(crate) fn refresh_signal_index<S: SignalStorage>(
    storage: &S,
    session_id: &str,
) -> Result<(), CliError> {
    let resolved = storage
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    storage.sync_signal_index(session_id, &signals)
}

pub(crate) fn session_detail<S: SignalStorage>(
    session_id: &str,
    storage: Option<&S>,
) -> Result<SessionDetail, CliError> {
    if let Some(storage) = storage {
        return storage.session_detail(session_id);
    }
    let resolved = index::resolve_session(session_id)?;
    snapshot::session_detail_from_resolved(&resolved)
}

#[must_use]
pub fn pending_signal_record(
    session_id: &str,
    runtime: &str,
    agent_id: &str,
    signal: &Signal,
) -> SessionSignalRecord {
    SessionSignalRecord {
        runtime: runtime.to_string(),
        agent_id: agent_id.to_string(),
        session_id: session_id.to_string(),
        status: SessionSignalStatus::Pending,
        signal: signal.clone(),
        acknowledgment: None,
    }
}

#[must_use]
pub fn build_signal_ack(
    session_id: &str,
    signal_id: &str,
    acknowledged_at: &str,
    result: AckResult,
    agent: &str,
    details: Option<String>,
) -> SignalAck {
    SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at: acknowledged_at.to_string(),
        result,
        agent: agent.to_string(),
        session_id: session_id.to_string(),
        details,
    }
}

#[must_use]
pub fn acknowledged_signal_record(
    runtime: &str,
    agent_id: &str,
    signal: &Signal,
    acknowledgment: &SignalAck,
) -> SessionSignalRecord {
    SessionSignalRecord {
        runtime: runtime.to_string(),
        agent_id: agent_id.to_string(),
        session_id: acknowledgment.session_id.clone(),
        status: SessionSignalStatus::from_ack_result(acknowledgment.result),
        signal: signal.clone(),
        acknowledgment: Some(acknowledgment.clone()),
    }
}
