use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;
use std::time::Instant;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::errors::CliError;
use super::super::{
    SESSION_LIVENESS_REFRESH_CACHE, SESSION_LIVENESS_REFRESH_TTL,
    liveness_project_dir_for_resolved, refresh_resolved_session_from_files_if_newer,
    sync_resolved_liveness, sync_resolved_liveness_async,
};

pub(super) fn reconcile_active_session_liveness_for_reads(
    _include_all: bool,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = db
        .list_session_summaries()?
        .into_iter()
        .filter(|state| state.status.is_liveness_eligible() && state.metrics.agent_count > 0)
        .map(|state| state.session_id)
        .collect();
    let stale_session_ids = stale_session_ids_for_liveness_refresh_now(session_ids, Instant::now());
    for session_id in stale_session_ids {
        if let Err(error) = reconcile_session_liveness_for_read(&session_id, Some(db)) {
            clear_session_liveness_refresh_cache_entry(&session_id);
            return Err(error);
        }
    }
    Ok(())
}

pub(super) async fn reconcile_active_session_liveness_for_reads_async(
    _include_all: bool,
    async_db: Option<&AsyncDaemonDb>,
) -> Result<(), CliError> {
    let Some(async_db) = async_db else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = async_db
        .list_session_summaries()
        .await?
        .into_iter()
        .filter(|state| state.status.is_liveness_eligible() && state.metrics.agent_count > 0)
        .map(|state| state.session_id)
        .collect();
    let stale_session_ids = stale_session_ids_for_liveness_refresh_now(session_ids, Instant::now());
    for session_id in stale_session_ids {
        if let Err(error) =
            reconcile_session_liveness_for_read_async(&session_id, Some(async_db)).await
        {
            clear_session_liveness_refresh_cache_entry(&session_id);
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) fn stale_session_ids_for_liveness_refresh(
    cache: &mut BTreeMap<String, Instant>,
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    cache.retain(|session_id, _| session_ids.contains(session_id));
    let mut stale_session_ids = Vec::new();
    for session_id in session_ids {
        let should_refresh = cache.get(&session_id).is_none_or(|last_refresh| {
            now.saturating_duration_since(*last_refresh) >= SESSION_LIVENESS_REFRESH_TTL
        });
        if should_refresh {
            cache.insert(session_id.clone(), now);
            stale_session_ids.push(session_id);
        }
    }
    stale_session_ids
}

pub(super) fn stale_session_ids_for_liveness_refresh_now(
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    let cache = SESSION_LIVENESS_REFRESH_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    match cache.lock() {
        Ok(mut cache) => stale_session_ids_for_liveness_refresh(&mut cache, session_ids, now),
        Err(_) => session_ids.into_iter().collect(),
    }
}

pub(crate) fn clear_session_liveness_refresh_cache_entry(session_id: &str) {
    let Some(cache) = SESSION_LIVENESS_REFRESH_CACHE.get() else {
        return;
    };
    let Ok(mut cache) = cache.lock() else {
        return;
    };
    cache.remove(session_id);
}

pub(super) fn reconcile_session_liveness_for_read(
    session_id: &str,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return Ok(());
    };
    let Some(mut resolved) = db.resolve_session(session_id)? else {
        return Ok(());
    };
    refresh_resolved_session_from_files_if_newer(db, &mut resolved)?;
    let Some(project_dir) = liveness_project_dir_for_resolved(&resolved) else {
        return Ok(());
    };
    let _ = sync_resolved_liveness(db, &mut resolved, &project_dir)?;
    Ok(())
}

pub(super) async fn reconcile_session_liveness_for_read_async(
    session_id: &str,
    async_db: Option<&AsyncDaemonDb>,
) -> Result<(), CliError> {
    let Some(async_db) = async_db else {
        return Ok(());
    };
    let Some(mut resolved) = async_db.resolve_session(session_id).await? else {
        return Ok(());
    };
    let Some(project_dir) = liveness_project_dir_for_resolved(&resolved) else {
        return Ok(());
    };
    let _ = sync_resolved_liveness_async(async_db, &mut resolved, &project_dir).await?;
    Ok(())
}
