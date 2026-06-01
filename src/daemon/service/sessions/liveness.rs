use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;
use std::time::Instant;

use super::super::{
    SESSION_LIVENESS_REFRESH_CACHE, SESSION_LIVENESS_REFRESH_TTL,
    liveness_project_dir_for_resolved, refresh_resolved_session_from_files_if_newer,
    sync_resolved_liveness, sync_resolved_liveness_async,
};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::index::ResolvedSession;
use crate::errors::CliError;

pub(super) fn reconcile_active_session_liveness_for_reads(
    _include_all: bool,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = db.list_liveness_candidate_ids()?.into_iter().collect();
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
        .list_liveness_candidate_ids()
        .await?
        .into_iter()
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

pub(crate) fn reconcile_active_session_liveness_background(
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    reconcile_active_session_liveness_for_reads(true, db)
}

pub(crate) async fn reconcile_active_session_liveness_background_async(
    async_db: Option<&AsyncDaemonDb>,
) -> Result<(), CliError> {
    reconcile_active_session_liveness_for_reads_async(true, async_db).await
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

/// Decide whether a single session's read-time liveness reconcile is due,
/// recording `now` as the new refresh point when it is.
///
/// Unlike [`stale_session_ids_for_liveness_refresh`], this never evicts other
/// sessions' cache entries: a per-request read must not disturb the refresh
/// schedule of sessions it did not touch.
pub(crate) fn session_liveness_refresh_due_locked(
    cache: &mut BTreeMap<String, Instant>,
    session_id: &str,
    now: Instant,
) -> bool {
    let due = cache.get(session_id).is_none_or(|last_refresh| {
        now.saturating_duration_since(*last_refresh) >= SESSION_LIVENESS_REFRESH_TTL
    });
    if due {
        cache.insert(session_id.to_string(), now);
    }
    due
}

/// Whether the read-time liveness reconcile for `session_id` is due against the
/// shared refresh cache, marking it refreshed when so. A poisoned lock degrades
/// to always-due so liveness never silently stops reconciling.
pub(super) fn session_liveness_refresh_due_now(session_id: &str) -> bool {
    let cache = SESSION_LIVENESS_REFRESH_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    match cache.lock() {
        Ok(mut cache) => {
            session_liveness_refresh_due_locked(&mut cache, session_id, Instant::now())
        }
        Err(_) => true,
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
    reconcile_session_liveness_for_read_returning(session_id, db)?;
    Ok(())
}

/// Reconcile read-time liveness and return the reconciled resolved session so
/// callers that also need the session state avoid a second `resolve_session`.
///
/// The reconciliation persists any file refresh and liveness change before this
/// returns, so the in-memory `ResolvedSession` matches what a fresh resolve
/// would read back.
pub(super) fn reconcile_session_liveness_for_read_returning(
    session_id: &str,
    db: &DaemonDb,
) -> Result<Option<ResolvedSession>, CliError> {
    let Some(mut resolved) = db.resolve_session(session_id)? else {
        return Ok(None);
    };
    refresh_resolved_session_from_files_if_newer(db, &mut resolved)?;
    let Some(project_dir) = liveness_project_dir_for_resolved(&resolved) else {
        return Ok(Some(resolved));
    };
    let _ = sync_resolved_liveness(db, &mut resolved, &project_dir)?;
    Ok(Some(resolved))
}

pub(super) async fn reconcile_session_liveness_for_read_async(
    session_id: &str,
    async_db: Option<&AsyncDaemonDb>,
) -> Result<(), CliError> {
    let Some(async_db) = async_db else {
        return Ok(());
    };
    reconcile_session_liveness_for_read_returning_async(session_id, async_db).await?;
    Ok(())
}

/// Async counterpart of [`reconcile_session_liveness_for_read_returning`].
pub(super) async fn reconcile_session_liveness_for_read_returning_async(
    session_id: &str,
    async_db: &AsyncDaemonDb,
) -> Result<Option<ResolvedSession>, CliError> {
    let Some(mut resolved) = async_db.resolve_session(session_id).await? else {
        return Ok(None);
    };
    let Some(project_dir) = liveness_project_dir_for_resolved(&resolved) else {
        return Ok(Some(resolved));
    };
    let _ = sync_resolved_liveness_async(async_db, &mut resolved, &project_dir).await?;
    Ok(Some(resolved))
}
