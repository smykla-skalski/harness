use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use harness_kernel::errors::CliError;
use harness_session::index::ResolvedSession;

use crate::ports::AsyncSignalStorage;
use crate::reconcile::{liveness_project_dir_for_resolved, sync_resolved_liveness_async};

pub const SESSION_LIVENESS_REFRESH_TTL: Duration = Duration::from_secs(5);
static SESSION_LIVENESS_REFRESH_CACHE: OnceLock<Mutex<BTreeMap<String, Instant>>> = OnceLock::new();

/// Evict cache entries for sessions no longer present, and return the subset
/// of `session_ids` whose refresh window has elapsed.
#[must_use]
pub fn stale_session_ids_for_liveness_refresh(
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

#[must_use]
pub fn stale_session_ids_for_liveness_refresh_now(
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
pub fn session_liveness_refresh_due_locked(
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
#[must_use]
pub fn session_liveness_refresh_due_now(session_id: &str) -> bool {
    let cache = SESSION_LIVENESS_REFRESH_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    match cache.lock() {
        Ok(mut cache) => {
            session_liveness_refresh_due_locked(&mut cache, session_id, Instant::now())
        }
        Err(_) => true,
    }
}

pub fn clear_session_liveness_refresh_cache_entry(session_id: &str) {
    let Some(cache) = SESSION_LIVENESS_REFRESH_CACHE.get() else {
        return;
    };
    let Ok(mut cache) = cache.lock() else {
        return;
    };
    cache.remove(session_id);
}

/// # Errors
/// Returns an error when candidate listing or per-session reconciliation fails.
pub async fn reconcile_active_session_liveness_for_reads_async<A: AsyncSignalStorage>(
    _include_all: bool,
    storage: Option<&A>,
) -> Result<(), CliError> {
    let Some(storage) = storage else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = storage
        .list_liveness_candidate_ids()
        .await?
        .into_iter()
        .collect();
    let stale_session_ids = stale_session_ids_for_liveness_refresh_now(session_ids, Instant::now());
    for session_id in stale_session_ids {
        if let Err(error) =
            reconcile_session_liveness_for_read_async(&session_id, Some(storage)).await
        {
            clear_session_liveness_refresh_cache_entry(&session_id);
            return Err(error);
        }
    }
    Ok(())
}

/// # Errors
/// Returns an error when candidate listing or per-session reconciliation fails.
pub async fn reconcile_active_session_liveness_background_async<A: AsyncSignalStorage>(
    storage: Option<&A>,
) -> Result<(), CliError> {
    reconcile_active_session_liveness_for_reads_async(true, storage).await
}

/// # Errors
/// Returns an error when liveness reconciliation fails.
pub async fn reconcile_session_liveness_for_read_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: Option<&A>,
) -> Result<(), CliError> {
    let Some(storage) = storage else {
        return Ok(());
    };
    reconcile_session_liveness_for_read_returning_async(session_id, storage).await?;
    Ok(())
}

/// Async counterpart of the daemon's sync `reconcile_session_liveness_for_read_returning`,
/// which additionally refreshes from file-backed state before this reconcile runs.
///
/// # Errors
/// Returns an error when liveness reconciliation fails.
pub async fn reconcile_session_liveness_for_read_returning_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: &A,
) -> Result<Option<ResolvedSession>, CliError> {
    let Some(mut resolved) = storage.resolve_session(session_id).await? else {
        return Ok(None);
    };
    let Some(project_dir) = liveness_project_dir_for_resolved(&resolved) else {
        return Ok(Some(resolved));
    };
    let _ = sync_resolved_liveness_async(storage, &mut resolved, &project_dir).await?;
    Ok(Some(resolved))
}
