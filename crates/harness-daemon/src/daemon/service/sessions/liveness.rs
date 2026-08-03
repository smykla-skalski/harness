#[cfg(test)]
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::time::Instant;

use super::super::{
    liveness_project_dir_for_resolved, refresh_resolved_session_from_files_if_newer,
    sync_resolved_liveness,
};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::index::ResolvedSession;
use harness_kernel::errors::CliError;
use crate::daemon::db::prelude::*;

pub(super) fn reconcile_active_session_liveness_for_reads(
    _include_all: bool,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = db.list_liveness_candidate_ids()?.into_iter().collect();
    let stale_session_ids =
        harness_daemon_session_service::stale_session_ids_for_liveness_refresh_now(
            session_ids,
            Instant::now(),
        );
    for session_id in stale_session_ids {
        if let Err(error) = reconcile_session_liveness_for_read(&session_id, Some(db)) {
            harness_daemon_session_service::clear_session_liveness_refresh_cache_entry(&session_id);
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
    harness_daemon_session_service::reconcile_active_session_liveness_background_async(async_db)
        .await
}

#[cfg(test)]
pub(crate) fn stale_session_ids_for_liveness_refresh(
    cache: &mut BTreeMap<String, Instant>,
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    harness_daemon_session_service::stale_session_ids_for_liveness_refresh(cache, session_ids, now)
}

#[cfg(test)]
pub(crate) fn session_liveness_refresh_due_locked(
    cache: &mut BTreeMap<String, Instant>,
    session_id: &str,
    now: Instant,
) -> bool {
    harness_daemon_session_service::session_liveness_refresh_due_locked(cache, session_id, now)
}

#[cfg(test)]
pub(crate) fn clear_session_liveness_refresh_cache_entry(session_id: &str) {
    harness_daemon_session_service::clear_session_liveness_refresh_cache_entry(session_id);
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
