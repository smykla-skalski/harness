use std::path::{Path, PathBuf};

use harness_agents::runtime::signal::{
    AckResult, Signal, SignalAck, acknowledge_signal as write_signal_ack, read_pending_signals,
};
use harness_agents::runtime::{AgentRuntime, runtime_for_name};
use harness_daemon_snapshot as snapshot;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::index::ResolvedSession;
use harness_session::service as session_service;
use harness_session::types::{
    AgentRegistration, SessionLogEntry, SessionSignalRecord, SessionTransition,
};
use harness_session::wire::{SessionDetail, SignalAckRequest, SignalCancelRequest};
use harness_workspace::workspace::utc_now;

use crate::persistence::{
    acknowledged_signal_record, build_log_entry, build_signal_ack, effective_project_dir,
    session_not_found,
};
use crate::ports::AsyncSignalStorage;

pub(super) async fn resolved_session_for_signal_mutation(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
) -> Result<ResolvedSession, CliError> {
    storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

pub(super) async fn bump_session(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
) -> Result<(), CliError> {
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await
}

pub(super) async fn refresh_signal_index_for_resolved(
    storage: &impl AsyncSignalStorage,
    resolved: &ResolvedSession,
) -> Result<(), CliError> {
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    storage
        .sync_signal_index(&resolved.state.session_id, &signals)
        .await
}

async fn signal_already_acknowledged(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
    signal_id: &str,
) -> Result<bool, CliError> {
    let signals = storage.load_signals(session_id).await?;
    Ok(signals
        .iter()
        .any(|signal| signal.signal.signal_id == signal_id && signal.acknowledgment.is_some()))
}

async fn indexed_signal_record(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
) -> Result<Option<SessionSignalRecord>, CliError> {
    Ok(storage
        .load_signals(session_id)
        .await?
        .into_iter()
        .find(|record| record.agent_id == agent_id && record.signal.signal_id == signal_id))
}

fn acknowledged_signal_transition(
    signal_id: &str,
    agent_id: &str,
    result: AckResult,
) -> SessionTransition {
    session_service::log_signal_acknowledged(signal_id, agent_id, result)
}

fn assigned_task_log_entry(session_id: &str, task_id: &str, agent_id: &str) -> SessionLogEntry {
    build_log_entry(
        session_id,
        session_service::log_task_assigned(task_id, agent_id),
        Some(agent_id),
        None,
    )
}

fn acknowledged_signal_log_entry(
    session_id: &str,
    signal_id: &str,
    agent_id: &str,
    result: AckResult,
) -> SessionLogEntry {
    build_log_entry(
        session_id,
        acknowledged_signal_transition(signal_id, agent_id, result),
        Some(agent_id),
        None,
    )
}

fn signal_session_id_for_agent<'a>(session_id: &'a str, agent: &'a AgentRegistration) -> &'a str {
    agent.agent_session_id.as_deref().unwrap_or(session_id)
}

pub(super) fn runtime_for_agent(runtime_name: &str) -> Result<&'static dyn AgentRuntime, CliError> {
    runtime_for_name(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{runtime_name}'"
        )))
    })
}

fn pending_signal_dir(
    resolved: &ResolvedSession,
    session_id: &str,
    agent_id: &str,
    project_dir: &Path,
) -> Result<PathBuf, CliError> {
    let agent = resolved.state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found in session '{session_id}'"
        )))
    })?;
    let runtime = runtime_for_agent(agent.runtime.runtime_name())?;
    Ok(runtime.signal_dir(project_dir, signal_session_id_for_agent(session_id, agent)))
}

fn cancel_ack_record(
    session_id: &str,
    actor_id: &str,
    signal_id: &str,
    signal_session_id: &str,
) -> SignalAck {
    SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at: utc_now(),
        result: AckResult::Rejected,
        agent: signal_session_id.to_string(),
        session_id: session_id.to_string(),
        details: Some(format!("cancelled by {actor_id}")),
    }
}

fn write_signal_ack_artifact(
    resolved: &ResolvedSession,
    session_id: &str,
    request: &SignalAckRequest,
    project_dir: &Path,
) -> Result<(), CliError> {
    let Some(agent) = resolved.state.agents.get(&request.agent_id) else {
        return Ok(());
    };
    let runtime = runtime_for_agent(agent.runtime.runtime_name())?;
    let signal_session_id = signal_session_id_for_agent(session_id, agent);
    write_signal_ack(
        &runtime.signal_dir(project_dir, signal_session_id),
        &SignalAck {
            signal_id: request.signal_id.clone(),
            acknowledged_at: utc_now(),
            result: request.result,
            agent: signal_session_id.to_string(),
            session_id: session_id.to_string(),
            details: None,
        },
    )
}

struct SignalAckOutcome {
    result: AckResult,
    started_task: Option<String>,
    signal: SessionSignalRecord,
}

async fn load_signal_ack_target(
    storage: &impl AsyncSignalStorage,
    resolved: &ResolvedSession,
    request: &SignalAckRequest,
    project_dir: &Path,
) -> Result<Option<SessionSignalRecord>, CliError> {
    if let Some(signal) = indexed_signal_record(
        storage,
        &resolved.state.session_id,
        &request.agent_id,
        &request.signal_id,
    )
    .await?
    {
        Ok(Some(signal))
    } else {
        session_service::load_signal_record_for_agent_from_state(
            &resolved.state,
            &request.agent_id,
            &request.signal_id,
            project_dir,
        )
    }
}

async fn persist_signal_ack_state(
    storage: &impl AsyncSignalStorage,
    resolved: &ResolvedSession,
    request: &SignalAckRequest,
    signal: SessionSignalRecord,
) -> Result<SignalAckOutcome, CliError> {
    let result = session_service::normalize_signal_ack_result(&signal.signal, request.result);
    let now = utc_now();
    let started_task = storage
        .update_session_state_immediate(&resolved.state.session_id, |state| {
            let started_task = session_service::apply_signal_ack_result(
                state,
                &request.agent_id,
                &signal.signal,
                result,
                &now,
            );
            session_service::refresh_session(state, &now);
            Ok(started_task)
        })
        .await?;
    storage.sync_file_state(&resolved.state.session_id).await?;

    Ok(SignalAckOutcome {
        result,
        started_task,
        signal,
    })
}

async fn append_started_task_log(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
    agent_id: &str,
    started_task: Option<&str>,
) -> Result<(), CliError> {
    let Some(task_id) = started_task else {
        return Ok(());
    };
    storage
        .append_log_entry(&assigned_task_log_entry(session_id, task_id, agent_id))
        .await
}

fn ensure_pending_signal_exists(
    pending: &[Signal],
    request: &SignalCancelRequest,
) -> Result<(), CliError> {
    if pending
        .iter()
        .any(|signal| signal.signal_id == request.signal_id)
    {
        return Ok(());
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "signal '{}' is not pending for agent '{}'",
        request.signal_id, request.agent_id
    ))))
}

async fn persist_cancel_signal_state(
    storage: &impl AsyncSignalStorage,
    resolved: &ResolvedSession,
    session_id: &str,
    request: &SignalCancelRequest,
    ack: &SignalAck,
) -> Result<(), CliError> {
    storage
        .append_log_entry(&build_log_entry(
            session_id,
            acknowledged_signal_transition(
                &request.signal_id,
                &request.agent_id,
                AckResult::Rejected,
            ),
            Some(&request.actor),
            None,
        ))
        .await?;
    if let Some(signal) =
        indexed_signal_record(storage, session_id, &request.agent_id, &request.signal_id).await?
    {
        storage
            .merge_signal_records(
                session_id,
                &[acknowledged_signal_record(
                    &signal.runtime,
                    &request.agent_id,
                    &signal.signal,
                    ack,
                )],
            )
            .await?;
    } else {
        refresh_signal_index_for_resolved(storage, resolved).await?;
    }
    Ok(())
}

async fn persist_acknowledged_signal_index(
    storage: &impl AsyncSignalStorage,
    resolved: &ResolvedSession,
    session_id: &str,
    request: &SignalAckRequest,
    outcome: &SignalAckOutcome,
) -> Result<(), CliError> {
    let signal = &outcome.signal;
    let ack_agent = resolved
        .state
        .agents
        .get(&request.agent_id)
        .and_then(|agent| agent.agent_session_id.as_deref())
        .unwrap_or(session_id);
    storage
        .merge_signal_records(
            session_id,
            &[acknowledged_signal_record(
                &signal.runtime,
                &request.agent_id,
                &signal.signal,
                &build_signal_ack(
                    session_id,
                    &signal.signal.signal_id,
                    &utc_now(),
                    outcome.result,
                    ack_agent,
                    None,
                ),
            )],
        )
        .await
}

/// Cancel a pending signal while persisting the canonical async DB snapshot.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the signal cannot be
/// cancelled, or canonical persistence fails.
pub async fn cancel_signal_async(
    session_id: &str,
    request: &SignalCancelRequest,
    storage: &impl AsyncSignalStorage,
) -> Result<SessionDetail, CliError> {
    let resolved = resolved_session_for_signal_mutation(storage, session_id).await?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let signal_dir = pending_signal_dir(&resolved, session_id, &request.agent_id, &project_dir)?;
    let pending = read_pending_signals(&signal_dir)?;
    ensure_pending_signal_exists(&pending, request)?;

    let agent = resolved
        .state
        .agents
        .get(&request.agent_id)
        .ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{}' not found in session '{session_id}'",
                request.agent_id
            )))
        })?;
    let ack = cancel_ack_record(
        session_id,
        &request.actor,
        &request.signal_id,
        signal_session_id_for_agent(session_id, agent),
    );
    write_signal_ack(&signal_dir, &ack)?;
    persist_cancel_signal_state(storage, &resolved, session_id, request, &ack).await?;
    bump_session(storage, session_id).await?;
    storage.session_detail(session_id).await
}

/// Record a signal acknowledgment while keeping the async DB authoritative.
///
/// # Errors
/// Returns `CliError` when signal or persistence updates fail.
pub async fn record_signal_ack_direct_async(
    session_id: &str,
    request: &SignalAckRequest,
    storage: &impl AsyncSignalStorage,
) -> Result<(), CliError> {
    if signal_already_acknowledged(storage, session_id, &request.signal_id).await? {
        return Ok(());
    }
    record_signal_ack_direct_async_inner(session_id, request, storage).await
}

async fn record_signal_ack_direct_async_inner(
    session_id: &str,
    request: &SignalAckRequest,
    storage: &impl AsyncSignalStorage,
) -> Result<(), CliError> {
    let resolved = resolved_session_for_signal_mutation(storage, session_id).await?;
    let project_dir = Path::new(&request.project_dir);
    let Some(signal) = load_signal_ack_target(storage, &resolved, request, project_dir).await?
    else {
        return Ok(());
    };
    if !session_service::signal_belongs_to_session_route(
        &signal.signal,
        session_id,
        &request.agent_id,
    ) {
        return Ok(());
    }
    write_signal_ack_artifact(&resolved, session_id, request, project_dir)?;
    let outcome = persist_signal_ack_state(storage, &resolved, request, signal).await?;
    append_signal_ack_log_entries(storage, session_id, request, &outcome).await?;
    let resolved = resolved_session_for_signal_mutation(storage, session_id).await?;
    persist_acknowledged_signal_index(storage, &resolved, session_id, request, &outcome).await?;
    bump_session(storage, session_id).await
}

async fn append_signal_ack_log_entries(
    storage: &impl AsyncSignalStorage,
    session_id: &str,
    request: &SignalAckRequest,
    outcome: &SignalAckOutcome,
) -> Result<(), CliError> {
    append_started_task_log(
        storage,
        session_id,
        &request.agent_id,
        outcome.started_task.as_deref(),
    )
    .await?;
    storage
        .append_log_entry(&acknowledged_signal_log_entry(
            session_id,
            &request.signal_id,
            &request.agent_id,
            outcome.result,
        ))
        .await
}
