use rusqlite::params;
use sqlx::query;

use super::remote_identity::prune_remote_audit_events_in_transaction;
use super::remote_identity_async::prune_remote_audit_events_in_transaction as prune_remote_audit_events_async_in_transaction;
use super::{AsyncDaemonDb, CliError, DaemonDb, db_error};

const INSERT_REMOTE_PAIRING_EXPIRATION_SQL: &str = "
INSERT OR IGNORE INTO remote_audit_events (
    event_id, recorded_at, request_id, client_id, route_or_method, scope,
    scope_decision, outcome, remote_addr, error_detail, metadata_json
)
SELECT
    'remote-pair-expire-' || pairing_id,
    expires_at,
    NULL,
    NULL,
    'remote.pair.expire',
    'read',
    'denied',
    'failure',
    NULL,
    'remote pairing code expired',
    '{}'
FROM remote_pairing_codes
WHERE pairing_id = ?1
  AND claimed_at IS NULL
  AND unixepoch(expires_at) <= unixepoch(?2)";

const INSERT_EXPIRED_REMOTE_PAIRINGS_SQL: &str = "
INSERT OR IGNORE INTO remote_audit_events (
    event_id, recorded_at, request_id, client_id, route_or_method, scope,
    scope_decision, outcome, remote_addr, error_detail, metadata_json
)
SELECT
    'remote-pair-expire-' || pairing_id,
    expires_at,
    NULL,
    NULL,
    'remote.pair.expire',
    'read',
    'denied',
    'failure',
    NULL,
    'remote pairing code expired',
    '{}'
FROM remote_pairing_codes
WHERE claimed_at IS NULL
  AND unixepoch(expires_at) <= unixepoch(?1)";

impl DaemonDb {
    /// Record one pairing's lifecycle expiration at most once.
    ///
    /// # Errors
    /// Returns [`CliError`] when the expiration audit cannot be persisted.
    pub(crate) fn record_remote_pairing_expiration(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<bool, CliError> {
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin remote pairing expiration audit: {error}")))?;
        let changed = transaction
            .execute(
                INSERT_REMOTE_PAIRING_EXPIRATION_SQL,
                params![pairing_id, now],
            )
            .map_err(|error| {
                db_error(format!(
                    "record remote pairing expiration {pairing_id}: {error}"
                ))
            })?;
        prune_remote_audit_events_in_transaction(&transaction)?;
        transaction.commit().map_err(|error| {
            db_error(format!("commit remote pairing expiration audit: {error}"))
        })?;
        Ok(changed == 1)
    }
}

impl AsyncDaemonDb {
    /// Record every currently expired, unclaimed pairing at most once.
    ///
    /// # Errors
    /// Returns [`CliError`] when the expiration sweep cannot be persisted.
    pub(crate) async fn record_expired_remote_pairings(&self, now: &str) -> Result<u64, CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin expired remote pairing audit sweep: {error}"))
        })?;
        let changed = query(INSERT_EXPIRED_REMOTE_PAIRINGS_SQL)
            .bind(now)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("record expired remote pairings: {error}")))?
            .rows_affected();
        prune_remote_audit_events_async_in_transaction(&mut transaction).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit expired remote pairing audit sweep: {error}"
            ))
        })?;
        Ok(changed)
    }
}
