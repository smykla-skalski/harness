use std::path::{Path, PathBuf};

use super::{
    AgentRegistration, CliError, CliErrorKind, SessionDetail, SessionLogEntry, SessionTransition,
    SignalAck, SignalAckRequest, SignalCancelRequest, acknowledged_signal_record, build_log_entry,
    build_signal_ack, effective_project_dir, session_detail_from_async_daemon_db,
    session_not_found, session_service, snapshot, utc_now, write_signal_ack,
};
use crate::agents::runtime::signal::{AckResult, Signal, read_pending_signals};
use crate::agents::runtime::{AgentRuntime, runtime_for_name};
use crate::daemon::index::ResolvedSession;
use crate::session::types::SessionSignalRecord;

pub(super) async fn resolved_session_for_signal_mutation(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<ResolvedSession, CliError> {
    async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

pub(super) async fn bump_session(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await
}

pub(super) async fn refresh_signal_index_for_resolved(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
) -> Result<(), CliError> {
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    async_db
        .sync_signal_index(&resolved.state.session_id, &signals)
        .await
}

async fn signal_already_acknowledged(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    signal_id: &str,
) -> Result<bool, CliError> {
    let signals = async_db.load_signals(session_id).await?;
    Ok(signals
        .iter()
        .any(|signal| signal.signal.signal_id == signal_id && signal.acknowledgment.is_some()))
}

async fn indexed_signal_record(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
) -> Result<Option<SessionSignalRecord>, CliError> {
    Ok(async_db
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
    let runtime = runtime_for_agent(&agent.runtime)?;
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
    let runtime = runtime_for_agent(&agent.runtime)?;
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
    indexed_signal: Option<SessionSignalRecord>,
}

async fn persist_signal_ack_state(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    request: &SignalAckRequest,
    project_dir: &Path,
) -> Result<SignalAckOutcome, CliError> {
    let signal = if let Some(signal) = indexed_signal_record(
        async_db,
        &resolved.state.session_id,
        &request.agent_id,
        &request.signal_id,
    )
    .await?
    {
        Some(signal)
    } else {
        session_service::load_signal_record_for_agent_from_state(
            &resolved.state,
            &request.agent_id,
            &request.signal_id,
            project_dir,
        )?
    };
    let result = signal.as_ref().map_or(request.result, |record| {
        session_service::normalize_signal_ack_result(&record.signal, request.result)
    });
    let mut started_task = None;

    if let Some(signal) = signal.as_ref() {
        let now = utc_now();
        started_task = session_service::apply_signal_ack_result(
            &mut resolved.state,
            &request.agent_id,
            &signal.signal,
            result,
            &now,
        );
        session_service::refresh_session(&mut resolved.state, &now);
        async_db
            .save_session_state(&resolved.project.project_id, &resolved.state)
            .await?;
    }

    Ok(SignalAckOutcome {
        result,
        started_task,
        indexed_signal: signal,
    })
}

async fn append_started_task_log(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    agent_id: &str,
    started_task: Option<&str>,
) -> Result<(), CliError> {
    let Some(task_id) = started_task else {
        return Ok(());
    };
    async_db
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
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    session_id: &str,
    request: &SignalCancelRequest,
    ack: &SignalAck,
) -> Result<(), CliError> {
    async_db
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
        indexed_signal_record(async_db, session_id, &request.agent_id, &request.signal_id).await?
    {
        async_db
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
        refresh_signal_index_for_resolved(async_db, resolved).await?;
    }
    Ok(())
}

async fn persist_acknowledged_signal_index(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    session_id: &str,
    request: &SignalAckRequest,
    outcome: &SignalAckOutcome,
) -> Result<(), CliError> {
    let Some(signal) = outcome.indexed_signal.as_ref() else {
        return refresh_signal_index_for_resolved(async_db, resolved).await;
    };
    let ack_agent = resolved
        .state
        .agents
        .get(&request.agent_id)
        .and_then(|agent| agent.agent_session_id.as_deref())
        .unwrap_or(session_id);
    async_db
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
pub(crate) async fn cancel_signal_async(
    session_id: &str,
    request: &SignalCancelRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let resolved = resolved_session_for_signal_mutation(async_db, session_id).await?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let signal_dir = pending_signal_dir(&resolved, session_id, &request.agent_id, &project_dir)?;
    let pending = read_pending_signals(&signal_dir)?;
    ensure_pending_signal_exists(&pending, request)?;

    let agent = resolved
        .state
        .agents
        .get(&request.agent_id)
        .expect("agent already validated");
    let ack = cancel_ack_record(
        session_id,
        &request.actor,
        &request.signal_id,
        signal_session_id_for_agent(session_id, agent),
    );
    write_signal_ack(&signal_dir, &ack)?;
    persist_cancel_signal_state(async_db, &resolved, session_id, request, &ack).await?;
    bump_session(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Record a signal acknowledgment while keeping the async DB authoritative.
///
/// # Errors
/// Returns `CliError` when signal or persistence updates fail.
pub(crate) async fn record_signal_ack_direct_async(
    session_id: &str,
    request: &SignalAckRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    if signal_already_acknowledged(async_db, session_id, &request.signal_id).await? {
        return Ok(());
    }
    record_signal_ack_direct_async_inner(session_id, request, async_db).await
}

async fn record_signal_ack_direct_async_inner(
    session_id: &str,
    request: &SignalAckRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    let mut resolved = resolved_session_for_signal_mutation(async_db, session_id).await?;
    let project_dir = Path::new(&request.project_dir);
    write_signal_ack_artifact(&resolved, session_id, request, project_dir)?;
    let outcome = persist_signal_ack_state(async_db, &mut resolved, request, project_dir).await?;

    append_started_task_log(
        async_db,
        session_id,
        &request.agent_id,
        outcome.started_task.as_deref(),
    )
    .await?;
    async_db
        .append_log_entry(&acknowledged_signal_log_entry(
            session_id,
            &request.signal_id,
            &request.agent_id,
            outcome.result,
        ))
        .await?;
    persist_acknowledged_signal_index(async_db, &resolved, session_id, request, &outcome).await?;
    bump_session(async_db, session_id).await
}
