//! Revoking a pairing that belongs to somebody else.
//!
//! Self-revocation destroys the caller's own credential and lives beside the
//! clients table. This is the other direction: an authorized caller cutting off
//! a device it did not claim, or withdrawing a link nobody has claimed yet.

use sqlx::{Row, query};

use super::remote_identity::INSERT_REMOTE_AUDIT_EVENT_SQL;
use super::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::remote_identity::RemoteAuditEvent;

/// What revoking found to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemotePairingRevokeOutcome {
    /// The device that claimed this link can no longer reach the daemon.
    DeviceRevoked,
    /// Nobody had claimed it, and now nobody can.
    LinkWithdrawn,
    /// Already revoked, by this route or by a client revoking itself.
    AlreadyRevoked,
    /// No such pairing.
    NotFound,
}

impl AsyncDaemonDb {
    /// Revoke a pairing and record who did it, atomically.
    ///
    /// A claimed link is revoked by cutting off the device it became, because
    /// that credential is what still reaches the daemon. An unclaimed one is
    /// marked on the pairing row instead, since there is no client yet, and the
    /// claim path refuses a link marked that way.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) async fn revoke_remote_pairing_with_audit(
        &self,
        pairing_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<RemotePairingRevokeOutcome, CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin remote pairing revoke transaction: {error}"))
        })?;

        let row = query(
            "SELECT claimed_client_id, json_extract(metadata_json, '$.revoked_at') AS revoked_at
             FROM remote_pairing_codes
             WHERE pairing_id = ?1",
        )
        .bind(pairing_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load pairing {pairing_id} to revoke: {error}")))?;

        let Some(row) = row else {
            transaction.rollback().await.map_err(|error| {
                db_error(format!("rollback missing remote pairing revoke: {error}"))
            })?;
            return Ok(RemotePairingRevokeOutcome::NotFound);
        };
        let claimed_client_id: Option<String> = row
            .try_get("claimed_client_id")
            .map_err(|error| db_error(format!("read claimed client for {pairing_id}: {error}")))?;
        let already: Option<String> = row
            .try_get("revoked_at")
            .map_err(|error| db_error(format!("read revocation for {pairing_id}: {error}")))?;

        let outcome = match (claimed_client_id, already) {
            (_, Some(_)) => RemotePairingRevokeOutcome::AlreadyRevoked,
            (Some(client_id), None) => {
                let changed = query(
                    "UPDATE remote_clients
                     SET revoked_at = ?2
                     WHERE client_id = ?1 AND revoked_at IS NULL",
                )
                .bind(&client_id)
                .bind(revoked_at)
                .execute(transaction.as_mut())
                .await
                .map_err(|error| db_error(format!("revoke device {client_id}: {error}")))?
                .rows_affected();
                if changed == 1 {
                    RemotePairingRevokeOutcome::DeviceRevoked
                } else {
                    // The device revoked itself between the read and here, or
                    // an operator did it on the host. Either way it is off.
                    RemotePairingRevokeOutcome::AlreadyRevoked
                }
            }
            (None, None) => {
                query(
                    "UPDATE remote_pairing_codes
                     SET metadata_json = json_set(metadata_json, '$.revoked_at', ?2)
                     WHERE pairing_id = ?1 AND claimed_at IS NULL",
                )
                .bind(pairing_id)
                .bind(revoked_at)
                .execute(transaction.as_mut())
                .await
                .map_err(|error| db_error(format!("withdraw link {pairing_id}: {error}")))?;
                RemotePairingRevokeOutcome::LinkWithdrawn
            }
        };

        // Recorded even when there was nothing left to revoke, because an
        // attempt to cut off somebody else's device is worth seeing in the
        // trail whether or not it changed anything.
        query(INSERT_REMOTE_AUDIT_EVENT_SQL)
            .bind(&audit.event_id)
            .bind(&audit.recorded_at)
            .bind(audit.request_id.as_deref())
            .bind(audit.client_id.as_deref())
            .bind(&audit.route_or_method)
            .bind(audit.scope.as_str())
            .bind(audit.scope_decision.as_str())
            .bind(audit.outcome.as_str())
            .bind(audit.remote_addr.as_deref())
            .bind(audit.error_detail())
            .bind(audit.metadata_json())
            .execute(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "insert remote pairing revoke audit {}: {error}",
                    audit.event_id
                ))
            })?;

        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote pairing revoke: {error}")))?;
        Ok(outcome)
    }
}
