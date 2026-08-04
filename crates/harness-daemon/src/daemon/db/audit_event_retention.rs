use super::{CliError, Connection, DaemonDb, db_error};

pub(crate) const PRUNE_REMOTE_AUDIT_EVENTS_SQL: &str = "
DELETE FROM remote_audit_events
WHERE event_id IN (
    SELECT event_id
    FROM remote_audit_events
    ORDER BY recorded_at DESC, event_id DESC
    LIMIT -1 OFFSET ?1
)";

/// Durable cap for remote authorization and lifecycle evidence.
///
/// The cap is intentionally independent of the in-memory unauthenticated
/// admission limiter: it survives process restarts and bounds every remote
/// audit writer, including pairing and lifecycle paths.
pub(crate) const REMOTE_AUDIT_EVENT_RETENTION_LIMIT: i64 = 10_000;

/// # Errors
/// Returns [`CliError`] when the retention transaction cannot complete.
pub(crate) fn prune_remote_audit_events_in_transaction(conn: &Connection) -> Result<u64, CliError> {
    conn.execute(
        PRUNE_REMOTE_AUDIT_EVENTS_SQL,
        [REMOTE_AUDIT_EVENT_RETENTION_LIMIT],
    )
    .map(|pruned| u64::try_from(pruned).unwrap_or(u64::MAX))
    .map_err(|error| db_error(format!("prune retained remote audit events: {error}")))
}

/// Prune retained remote audit events in their own transaction.
///
/// Callers that already hold a transaction (e.g. an audit-event write
/// wanting retention enforced in the same commit) should call
/// [`prune_remote_audit_events_in_transaction`] directly instead.
///
/// # Errors
/// Returns [`CliError`] when the retention transaction cannot complete.
pub(crate) fn prune_remote_audit_events(db: &DaemonDb) -> Result<u64, CliError> {
    let transaction = db
        .connection()
        .unchecked_transaction()
        .map_err(|error| db_error(format!("begin remote audit prune: {error}")))?;
    let pruned = prune_remote_audit_events_in_transaction(&transaction)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit remote audit prune: {error}")))?;
    Ok(pruned)
}
