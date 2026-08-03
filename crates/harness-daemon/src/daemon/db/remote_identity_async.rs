use sqlx::{Sqlite, Transaction, query};

use super::remote_identity::{PRUNE_REMOTE_AUDIT_EVENTS_SQL, REMOTE_AUDIT_EVENT_RETENTION_LIMIT};
use super::{CliError, db_error};

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
