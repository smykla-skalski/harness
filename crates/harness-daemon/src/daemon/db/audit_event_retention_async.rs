use sqlx::{Sqlite, Transaction, query};

use super::audit_event_retention::{
    PRUNE_REMOTE_AUDIT_EVENTS_SQL, REMOTE_AUDIT_EVENT_RETENTION_LIMIT,
};
use super::{AsyncDaemonDb, CliError, db_error};

/// # Errors
/// Returns [`CliError`] when the retention transaction cannot complete.
pub(crate) async fn prune_remote_audit_events_in_transaction(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<u64, CliError> {
    query(PRUNE_REMOTE_AUDIT_EVENTS_SQL)
        .bind(REMOTE_AUDIT_EVENT_RETENTION_LIMIT)
        .execute(transaction.as_mut())
        .await
        .map(|result| result.rows_affected())
        .map_err(|error| db_error(format!("prune retained remote audit events: {error}")))
}

/// Prune retained remote audit events in their own transaction.
///
/// Callers that already hold a transaction should call
/// [`prune_remote_audit_events_in_transaction`] directly instead.
///
/// # Errors
/// Returns [`CliError`] when the retention transaction cannot complete.
pub(crate) async fn prune_remote_audit_events(db: &AsyncDaemonDb) -> Result<u64, CliError> {
    let mut transaction = db
        .pool()
        .begin()
        .await
        .map_err(|error| db_error(format!("begin remote audit prune: {error}")))?;
    let pruned = prune_remote_audit_events_in_transaction(&mut transaction).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit remote audit prune: {error}")))?;
    Ok(pruned)
}
