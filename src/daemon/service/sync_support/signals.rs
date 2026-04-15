use crate::agents::runtime::signal::Signal;
use crate::daemon::db::DaemonDb;

use super::context::session_not_found;
use super::logs::build_log_entry;
use super::{
    AckResult, CliError, ExpiredPendingSignalIndexRecord, Path, PathBuf, SessionSignalRecord,
    SessionSignalStatus, SessionState, SessionTransition, SignalAck, pending_dir, runtime_for_name,
    session_service, snapshot, utc_now, write_signal_ack,
};

pub(crate) fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return session_service::record_signal_acknowledgment(
            session_id,
            agent_id,
            signal_id,
            result,
            project_dir,
        );
    };
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return session_service::record_signal_acknowledgment(
            session_id,
            agent_id,
            signal_id,
            result,
            project_dir,
        );
    };

    let already_logged = db.load_session_log(session_id)?.into_iter().any(|entry| {
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
    let signal = if let Some(signal) = db
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
    let mut started_task = None;

    if let Some(signal) = signal.as_ref() {
        started_task = session_service::apply_signal_ack_result(
            &mut state,
            agent_id,
            &signal.signal,
            result,
            &now,
        );
        session_service::refresh_session(&mut state, &now);
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
    }

    if let Some(signal) = signal.as_ref() {
        let ack_agent = state
            .agents
            .get(agent_id)
            .and_then(|agent| agent.agent_session_id.as_deref())
            .unwrap_or(session_id);
        db.merge_signal_records(
            session_id,
            &[acknowledged_signal_record(
                session_id,
                &signal.runtime,
                agent_id,
                &signal.signal,
                result,
                ack_agent,
                &now,
                None,
            )],
        )?;
    } else {
        refresh_signal_index_for_db(db, session_id)?;
    }

    if let Some(task_id) = started_task.as_deref() {
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, agent_id),
            Some(agent_id),
            None,
        ))?;
    }

    db.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_signal_acknowledged(signal_id, agent_id, result),
        Some(agent_id),
        None,
    ))?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(())
}

pub(crate) fn reconcile_expired_pending_signals_for_db(
    session_id: &str,
    db: &DaemonDb,
) -> Result<(), CliError> {
    let expired = db.load_expired_pending_signals(session_id)?;
    if expired.is_empty() {
        return Ok(());
    }

    let Some(state) = db.load_session_state_for_mutation(session_id)? else {
        return Ok(());
    };
    let Some(project_dir) = db.project_dir_for_session(session_id)? else {
        return Ok(());
    };
    let project_dir = PathBuf::from(project_dir);
    let context_root = session_service::signal_context_root(&project_dir);
    let mut needs_filesystem_fallback = false;

    for indexed_signal in expired {
        if !acknowledge_indexed_expired_signal(
            session_id,
            &project_dir,
            &context_root,
            &state,
            db,
            &indexed_signal,
        )? {
            needs_filesystem_fallback = true;
        }
    }

    if needs_filesystem_fallback {
        let expired =
            session_service::collect_expired_pending_signals_for_state(&state, &project_dir)?;
        for signal in expired {
            let ack = SignalAck {
                signal_id: signal.signal.signal_id.clone(),
                acknowledged_at: utc_now(),
                result: AckResult::Expired,
                agent: signal.signal_session_id.clone(),
                session_id: session_id.to_string(),
                details: Some("expired before agent acknowledged delivery".to_string()),
            };
            write_signal_ack(&signal.signal_dir, &ack)?;
            record_signal_ack(
                session_id,
                &signal.agent_id,
                &signal.signal.signal_id,
                AckResult::Expired,
                &project_dir,
                Some(db),
            )?;
        }
    }

    Ok(())
}

fn acknowledge_indexed_expired_signal(
    session_id: &str,
    project_dir: &Path,
    context_root: &Path,
    state: &SessionState,
    db: &DaemonDb,
    indexed_signal: &ExpiredPendingSignalIndexRecord,
) -> Result<bool, CliError> {
    let Some(agent) = state.agents.get(&indexed_signal.agent_id) else {
        return Ok(false);
    };
    let Some(runtime) = runtime_for_name(&indexed_signal.runtime) else {
        return Ok(false);
    };

    let Some((signal_session_id, signal_dir)) =
        session_service::signal_dirs_for_agent_in_context_root(
            runtime,
            session_id,
            agent.agent_session_id.as_deref(),
            context_root,
        )
        .into_iter()
        .find(|(_, signal_dir)| {
            pending_dir(signal_dir)
                .join(format!("{}.json", indexed_signal.signal.signal_id))
                .is_file()
        })
    else {
        return Ok(false);
    };

    let ack = SignalAck {
        signal_id: indexed_signal.signal.signal_id.clone(),
        acknowledged_at: utc_now(),
        result: AckResult::Expired,
        agent: signal_session_id,
        session_id: session_id.to_string(),
        details: Some("expired before agent acknowledged delivery".to_string()),
    };
    write_signal_ack(&signal_dir, &ack)?;
    record_signal_ack(
        session_id,
        &indexed_signal.agent_id,
        &indexed_signal.signal.signal_id,
        AckResult::Expired,
        project_dir,
        Some(db),
    )?;
    Ok(true)
}

pub(crate) fn refresh_signal_index_for_db(db: &DaemonDb, session_id: &str) -> Result<(), CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(session_id, &signals)
}

pub(crate) fn pending_signal_record(
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

pub(crate) fn acknowledged_signal_record(
    session_id: &str,
    runtime: &str,
    agent_id: &str,
    signal: &Signal,
    result: AckResult,
    ack_agent: &str,
    acknowledged_at: &str,
    details: Option<String>,
) -> SessionSignalRecord {
    SessionSignalRecord {
        runtime: runtime.to_string(),
        agent_id: agent_id.to_string(),
        session_id: session_id.to_string(),
        status: SessionSignalStatus::from_ack_result(result),
        signal: signal.clone(),
        acknowledgment: Some(SignalAck {
            signal_id: signal.signal_id.clone(),
            acknowledged_at: acknowledged_at.to_string(),
            result,
            agent: ack_agent.to_string(),
            session_id: session_id.to_string(),
            details,
        }),
    }
}
