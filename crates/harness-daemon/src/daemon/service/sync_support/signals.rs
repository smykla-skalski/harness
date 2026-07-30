use crate::daemon::db::DaemonDb;

use super::context::session_not_found;
use super::{
    AckResult, CliError, ExpiredPendingSignalIndexRecord, Path, PathBuf, SessionState, SignalAck,
    pending_dir, runtime_for_name, session_service, snapshot, utc_now, write_signal_ack,
};

pub(crate) fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    harness_daemon_session_service::record_signal_ack(
        session_id,
        agent_id,
        signal_id,
        result,
        project_dir,
        db,
    )
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
