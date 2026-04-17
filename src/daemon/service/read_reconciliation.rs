use crate::agents::runtime::{runtime_for_name, signal::pending_dir};
use crate::daemon::db::ExpiredPendingSignalIndexRecord;
use crate::session::types::{SessionState, SessionStatus};

use super::{
    AckResult, CliError, Path, PathBuf, ResolvedSession, SessionTransition, SignalAck,
    SignalAckRequest, build_log_entry, effective_project_dir, index,
    record_signal_ack_direct_async, session_not_found, session_service, snapshot, utc_now,
    write_signal_ack,
};

pub(crate) fn liveness_project_dir_for_resolved(resolved: &ResolvedSession) -> Option<PathBuf> {
    if resolved.state.status != SessionStatus::Active || !session_has_live_agents(&resolved.state) {
        return None;
    }
    // Keep the liveness path active even after the file-backed state disappears.
    // Otherwise imported sessions can remain falsely "active" in the daemon DB
    // forever once their last state/log artifacts are gone.
    Some(effective_project_dir(resolved).to_path_buf())
}

pub(crate) fn sync_resolved_liveness(
    db: &super::db::DaemonDb,
    resolved: &mut ResolvedSession,
    project_dir: &Path,
) -> Result<bool, CliError> {
    let now = utc_now();
    let mut result = session_service::LivenessSyncResult::default();
    let activity_map = session_service::collect_agent_activity_from_state(
        &resolved.state,
        &resolved.state.session_id,
        project_dir,
    );
    let changed = session_service::apply_liveness_transitions(
        &mut resolved.state,
        &activity_map,
        &now,
        &mut result,
    );
    if !changed {
        return Ok(false);
    }

    session_service::refresh_session(&mut resolved.state, &now);
    db.save_session_state(&resolved.project.project_id, &resolved.state)?;
    if !result.disconnected.is_empty() || !result.idled.is_empty() {
        db.append_log_entry(&build_log_entry(
            &resolved.state.session_id,
            SessionTransition::LivenessSynced {
                disconnected: result.disconnected.clone(),
                idled: result.idled.clone(),
            },
            None,
            Some("liveness sync"),
        ))?;
    }
    session_service::cleanup_dead_agent_signals(
        &activity_map,
        &result,
        &resolved.state.session_id,
        project_dir,
    );
    if !result.disconnected.is_empty() {
        let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
        db.sync_signal_index(&resolved.state.session_id, &signals)?;
    }
    db.bump_change(&resolved.state.session_id)?;
    db.bump_change("global")?;
    Ok(true)
}

pub(crate) async fn sync_resolved_liveness_async(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    project_dir: &Path,
) -> Result<bool, CliError> {
    let now = utc_now();
    let mut result = session_service::LivenessSyncResult::default();
    let activity_map = session_service::collect_agent_activity_from_state(
        &resolved.state,
        &resolved.state.session_id,
        project_dir,
    );
    let changed = session_service::apply_liveness_transitions(
        &mut resolved.state,
        &activity_map,
        &now,
        &mut result,
    );
    if !changed {
        return Ok(false);
    }

    session_service::refresh_session(&mut resolved.state, &now);
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    append_liveness_sync_log_async(async_db, &resolved.state.session_id, &result).await?;
    session_service::cleanup_dead_agent_signals(
        &activity_map,
        &result,
        &resolved.state.session_id,
        project_dir,
    );
    sync_disconnected_signal_index_async(async_db, resolved, &result).await?;
    async_db.bump_change(&resolved.state.session_id).await?;
    async_db.bump_change("global").await?;
    Ok(true)
}

async fn append_liveness_sync_log_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    result: &session_service::LivenessSyncResult,
) -> Result<(), CliError> {
    if result.disconnected.is_empty() && result.idled.is_empty() {
        return Ok(());
    }
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LivenessSynced {
                disconnected: result.disconnected.clone(),
                idled: result.idled.clone(),
            },
            None,
            Some("liveness sync"),
        ))
        .await
}

async fn sync_disconnected_signal_index_async(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    result: &session_service::LivenessSyncResult,
) -> Result<(), CliError> {
    if result.disconnected.is_empty() {
        return Ok(());
    }
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    async_db
        .sync_signal_index(&resolved.state.session_id, &signals)
        .await
}

pub(crate) async fn reconcile_expired_pending_signals_for_async_db(
    session_id: &str,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    let expired = async_db.load_expired_pending_signals(session_id).await?;
    if expired.is_empty() {
        return Ok(());
    }

    let Some(resolved) = async_db.resolve_session(session_id).await? else {
        return Ok(());
    };
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let context_root = session_service::signal_context_root(&project_dir);
    let needs_filesystem_fallback = acknowledge_indexed_expired_signals_async(
        session_id,
        &project_dir,
        &context_root,
        &resolved.state,
        async_db,
        &expired,
    )
    .await?;

    if needs_filesystem_fallback {
        reconcile_expired_pending_signals_from_files_async(
            session_id,
            &project_dir,
            &resolved.state,
            async_db,
        )
        .await?;
    }

    Ok(())
}

async fn acknowledge_indexed_expired_signals_async(
    session_id: &str,
    project_dir: &Path,
    context_root: &Path,
    state: &SessionState,
    async_db: &super::db::AsyncDaemonDb,
    expired: &[ExpiredPendingSignalIndexRecord],
) -> Result<bool, CliError> {
    let mut needs_filesystem_fallback = false;
    for indexed_signal in expired {
        if !acknowledge_indexed_expired_signal_async(
            session_id,
            project_dir,
            context_root,
            state,
            async_db,
            indexed_signal,
        )
        .await?
        {
            needs_filesystem_fallback = true;
        }
    }
    Ok(needs_filesystem_fallback)
}

async fn reconcile_expired_pending_signals_from_files_async(
    session_id: &str,
    project_dir: &Path,
    state: &SessionState,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    let expired = session_service::collect_expired_pending_signals_for_state(state, project_dir)?;
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
        record_signal_ack_direct_async(
            session_id,
            &SignalAckRequest {
                agent_id: signal.agent_id,
                signal_id: signal.signal.signal_id,
                result: AckResult::Expired,
                project_dir: project_dir.display().to_string(),
            },
            async_db,
        )
        .await?;
    }
    Ok(())
}

async fn acknowledge_indexed_expired_signal_async(
    session_id: &str,
    project_dir: &Path,
    context_root: &Path,
    state: &SessionState,
    async_db: &super::db::AsyncDaemonDb,
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
    record_signal_ack_direct_async(
        session_id,
        &SignalAckRequest {
            agent_id: indexed_signal.agent_id.clone(),
            signal_id: indexed_signal.signal.signal_id.clone(),
            result: AckResult::Expired,
            project_dir: project_dir.display().to_string(),
        },
        async_db,
    )
    .await?;
    Ok(true)
}

fn session_has_live_agents(state: &SessionState) -> bool {
    state.agents.values().any(|agent| agent.status.is_alive())
}

pub(crate) fn refresh_resolved_session_from_files_if_newer(
    db: &super::db::DaemonDb,
    resolved: &mut ResolvedSession,
) -> Result<(), CliError> {
    let file_resolved = match index::resolve_session(&resolved.state.session_id) {
        Ok(file_resolved) => file_resolved,
        Err(error) if error.code() == "KSRCLI090" => return Ok(()),
        Err(error) => return Err(error),
    };
    if file_resolved.state.state_version <= resolved.state.state_version {
        return Ok(());
    }

    let session_id = resolved.state.session_id.clone();
    let prepared = super::db::DaemonDb::prepare_session_import_from_resolved(&file_resolved)?;
    db.apply_prepared_session_resync(&prepared)?;
    *resolved = db
        .resolve_session(&session_id)?
        .ok_or_else(|| session_not_found(&session_id))?;
    Ok(())
}
