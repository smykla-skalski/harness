//! Revoking a pairing that belongs to somebody else.
//!
//! Self-revocation destroys the caller's own credential and lives beside the
//! clients table. This is the other direction: an authorized caller cutting off
//! a device it did not claim, or withdrawing a link nobody has claimed yet.

use sqlx::{Row, Sqlite, Transaction, query};

use super::remote_identity::INSERT_REMOTE_AUDIT_EVENT_SQL;
use super::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::remote_identity::{RemoteAuditEvent, RemoteAuditOutcome};

/// What revoking did, and when the revocation it reports actually happened.
///
/// The timestamp is not always the request time: a second revoke reports the
/// moment the device was really cut off, because a caller retrying otherwise
/// cannot tell its own attempt apart from the one that did the work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemotePairingRevoked {
    pub outcome: RemotePairingRevokeOutcome,
    pub revoked_at: String,
}

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

        let row = query(
            "SELECT p.claimed_client_id,
                    json_extract(p.metadata_json, '$.revoked_at') AS withdrawn_at,
                    c.revoked_at AS device_revoked_at
             FROM remote_pairing_codes p
             LEFT JOIN remote_clients c ON c.client_id = p.claimed_client_id
             WHERE p.pairing_id = ?1",
        )
        .bind(pairing_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load pairing {pairing_id} to revoke: {error}")))?;

        let Some(row) = row else {
            // Recorded rather than rolled back: an attempt to revoke an id that
            // does not exist is exactly what probing looks like, and the trail
            // is the only place it would show.
            // A failure, because nothing was revoked. Recording it as a
            // success would put an entry in the trail claiming a revocation
            // that never had a target.
            record_revoke_audit(&mut transaction, audit, RemoteAuditOutcome::Failure).await?;
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit missing remote pairing revoke: {error}"))
            })?;
            return Ok(RemotePairingRevoked {
                outcome: RemotePairingRevokeOutcome::NotFound,
                revoked_at: revoked_at.to_owned(),
            });
        };
        let claimed_client_id: Option<String> = row
            .try_get("claimed_client_id")
            .map_err(|error| db_error(format!("read claimed client for {pairing_id}: {error}")))?;
        let withdrawn_at: Option<String> = row
            .try_get("withdrawn_at")
            .map_err(|error| db_error(format!("read revocation for {pairing_id}: {error}")))?;
        let device_revoked_at: Option<String> = row.try_get("device_revoked_at").map_err(|error| {
            db_error(format!("read device revocation for {pairing_id}: {error}"))
        })?;
        // Either end can already carry it, and whichever does is the moment
        // that matters rather than the moment this request arrived.
        let already = withdrawn_at.or(device_revoked_at);

        let (outcome, effective_at) = match (claimed_client_id, already) {
            (_, Some(at)) => (RemotePairingRevokeOutcome::AlreadyRevoked, at),
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
                    (
                        RemotePairingRevokeOutcome::DeviceRevoked,
                        revoked_at.to_owned(),
                    )
                } else {
                    // The write lock makes this mean the device was revoked
                    // before the SELECT, which the guard above should have
                    // caught. Report the moment on the row rather than this
                    // one, so a retry never claims the revocation as its own.
                    let existing = stored_device_revocation(&mut transaction, &client_id).await?;
                    (
                        RemotePairingRevokeOutcome::AlreadyRevoked,
                        existing.unwrap_or_else(|| revoked_at.to_owned()),
                    )
                }
            }
            (None, None) => {
                let withdrawn = query(
                    "UPDATE remote_pairing_codes
                     SET metadata_json = json_set(metadata_json, '$.revoked_at', ?2)
                     WHERE pairing_id = ?1 AND claimed_at IS NULL",
                )
                .bind(pairing_id)
                .bind(revoked_at)
                .execute(transaction.as_mut())
                .await
                .map_err(|error| db_error(format!("withdraw link {pairing_id}: {error}")))?
                .rows_affected();
                if withdrawn != 1 {
                    // The guard is `claimed_at IS NULL`, so changing nothing
                    // means the link was claimed after all. Answering
                    // `LinkWithdrawn` would report that nobody can use the code
                    // at the moment somebody just did.
                    return Err(db_error(format!(
                        "pairing {pairing_id} was claimed while it was being withdrawn"
                    )));
                }
                (
                    RemotePairingRevokeOutcome::LinkWithdrawn,
                    revoked_at.to_owned(),
                )
            }
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

/// Recorded even when there was nothing left to revoke, because an attempt to
/// cut off somebody else's device is worth seeing in the trail whether or not
/// it changed anything.
async fn record_revoke_audit(
    transaction: &mut Transaction<'_, Sqlite>,
    audit: &RemoteAuditEvent,
    outcome: RemoteAuditOutcome,
) -> Result<(), CliError> {
    // The outcome is only known here, inside the transaction that decides it,
    // so it is applied rather than taken from the event the caller built.
    let audit = audit.clone().with_outcome(outcome);
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
    Ok(())
}

/// When a device was cut off, for reporting a revocation this request did not
/// perform.
async fn stored_device_revocation(
    transaction: &mut Transaction<'_, Sqlite>,
    client_id: &str,
) -> Result<Option<String>, CliError> {
    let row = query("SELECT revoked_at FROM remote_clients WHERE client_id = ?1")
        .bind(client_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read revocation for device {client_id}: {error}")))?;
    row.map_or(Ok(None), |row| {
        row.try_get("revoked_at").map_err(|error| {
            db_error(format!("read revocation for device {client_id}: {error}"))
        })
    })
}
