use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::index::ResolvedSession;
use crate::daemon::service::{
    reconcile_expired_pending_signals_for_async_db, reconcile_expired_pending_signals_for_db,
};
use crate::errors::CliError;

use super::liveness::{
    reconcile_session_liveness_for_read_returning,
    reconcile_session_liveness_for_read_returning_async,
};

/// Resolve a session once for a post-mutation snapshot broadcast.
///
/// The session-updated and session-extensions events both need the same
/// resolved state. Resolving once here lets the broadcaster build both events
/// from a single `ResolvedSession` instead of re-resolving for each, and runs
/// the read-time reconciliations (expired-signal expiry, then liveness) exactly
/// once. Returns `None` when the session no longer exists.
///
/// # Errors
/// Returns [`CliError`] when signal reconciliation, liveness reconciliation, or
/// the underlying resolve fails.
pub(crate) fn resolve_session_for_snapshot(
    session_id: &str,
    db: &DaemonDb,
) -> Result<Option<ResolvedSession>, CliError> {
    reconcile_expired_pending_signals_for_db(session_id, db)?;
    reconcile_session_liveness_for_read_returning(session_id, db)
}

/// Async counterpart of [`resolve_session_for_snapshot`].
///
/// # Errors
/// Returns [`CliError`] when signal reconciliation, liveness reconciliation, or
/// the underlying resolve fails.
pub(crate) async fn resolve_session_for_snapshot_async(
    session_id: &str,
    async_db: &AsyncDaemonDb,
) -> Result<Option<ResolvedSession>, CliError> {
    reconcile_expired_pending_signals_for_async_db(session_id, async_db).await?;
    reconcile_session_liveness_for_read_returning_async(session_id, async_db).await
}
