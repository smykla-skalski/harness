use sqlx::query;

use harness_kernel::errors::CliError;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::db_error;
use crate::daemon::db::remote_identity_async::prune_remote_audit_events_in_transaction as prune_remote_audit_events_async_in_transaction;
use crate::daemon::db::remote_pairing_revoke::{
    decide_pairing_revoke_outcome_in_tx, finish_missing_pairing_revoke, record_revoke_audit,
};
use crate::daemon::remote_identity::{RemoteAuditEvent, RemoteAuditOutcome};

use super::{RemotePairingAsyncQueries, RemotePairingRevoked};

impl RemotePairingAsyncQueries for AsyncDaemonDb {
    async fn record_expired_remote_pairings(&self, now: &str) -> Result<u64, CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin expired remote pairing audit sweep: {error}"))
        })?;
        let changed = query(
            "INSERT OR IGNORE INTO remote_audit_events (
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
               AND unixepoch(expires_at) <= unixepoch(?1)",
        )
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

    async fn revoke_remote_pairing_with_audit(
        &self,
        pairing_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<RemotePairingRevoked, CliError> {
        // Immediate rather than deferred: every branch below decides what to
        // write from what the SELECT saw, and a deferred transaction takes no
        // write lock until the first write, leaving room for the device to be
        // revoked or the link to be claimed in between.
        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| {
                db_error(format!("begin remote pairing revoke transaction: {error}"))
            })?;

        let Some((outcome, effective_at)) =
            decide_pairing_revoke_outcome_in_tx(&mut transaction, pairing_id, revoked_at).await?
        else {
            return finish_missing_pairing_revoke(transaction, audit, revoked_at).await;
        };

        record_revoke_audit(&mut transaction, audit, RemoteAuditOutcome::Success).await?;

        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote pairing revoke: {error}")))?;
        Ok(RemotePairingRevoked {
            outcome,
            revoked_at: effective_at,
        })
    }
}
