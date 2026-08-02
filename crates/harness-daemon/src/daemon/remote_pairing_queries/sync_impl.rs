use rusqlite::{OptionalExtension, params};

use harness_kernel::errors::CliError;

use crate::daemon::db::DaemonDb;
use crate::daemon::db::db_error;
use crate::daemon::db::remote_identity::{
    prune_remote_audit_events_in_transaction, record_remote_audit_event_in_transaction,
    upsert_remote_client_for_pairing,
};
use crate::daemon::db::remote_pairing::inventory::{
    SELECT_REMOTE_PAIRING_ENTRY_SQL, SELECT_REMOTE_PAIRING_INVENTORY_SQL, entry_from_columns,
    read_inventory_columns,
};
use crate::daemon::db::remote_pairing::{
    INSERT_REMOTE_PAIRING_SQL, ROUTE_REMOTE_PAIR_CLAIM, ROUTE_REMOTE_PAIR_CREATE,
    ROUTE_REMOTE_PAIR_DOMAIN, ROUTE_REMOTE_PAIR_EXPIRE, ROUTE_REMOTE_PAIR_INVALID,
    ROUTE_REMOTE_PAIR_REPLAY, ROUTE_REMOTE_PAIR_REVOKED, ROUTE_REMOTE_PAIR_UNKNOWN,
    decode_remote_pairing_metadata, encode_remote_pairing_metadata, load_remote_pairing_by_hash,
    pairing_is_expired, scopes_to_json,
};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteBearerToken,
    RemoteClientRegistration,
};
use crate::daemon::remote_identity_queries::RemoteIdentitySyncQueries;
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingClaimedClient, RemotePairingCodeHash,
    RemotePairingError, RemotePairingInventoryEntry, RemotePairingRecord, RemotePairingStatus,
    RemoteStoredPairing, validate_pairing_audit_event_id, validate_pairing_domain,
};

use super::{RemotePairingClaimCodeError, RemotePairingOwner, RemotePairingQueries};

impl RemotePairingQueries for DaemonDb {
    fn create_remote_pairing_code(
        &self,
        record: &RemotePairingRecord,
        audit_event_id: &str,
    ) -> Result<RemoteStoredPairing, CliError> {
        self.create_remote_pairing_code_with_audit(record, audit_event_id, None)
    }

    fn create_remote_pairing_code_with_audit(
        &self,
        record: &RemotePairingRecord,
        audit_event_id: &str,
        extra_audit: Option<&RemoteAuditEvent>,
    ) -> Result<RemoteStoredPairing, CliError> {
        validate_pairing_audit_event_id(audit_event_id)
            .map_err(|error| db_error(error.to_string()))?;
        let scopes_json = scopes_to_json(&record.scopes)?;
        let metadata_json = encode_remote_pairing_metadata(
            record.reviews_query.as_ref(),
            record.minted_for.as_ref(),
            record.minted_by.as_deref(),
            None,
        )?;
        let transaction = self
            .connection()
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin remote pairing create: {error}")))?;
        transaction
            .execute(
                INSERT_REMOTE_PAIRING_SQL,
                params![
                    record.pairing_id.as_str(),
                    record.code_hash.as_storage_value(),
                    record.role.as_str(),
                    scopes_json,
                    record.created_at.as_str(),
                    record.expires_at.as_str(),
                    metadata_json,
                ],
            )
            .map_err(|error| {
                db_error(format!(
                    "insert remote pairing {}: {error}",
                    record.pairing_id.as_str()
                ))
            })?;
        record_remote_audit_event_in_transaction(
            &transaction,
            &RemoteAuditEvent::new(
                audit_event_id,
                record.created_at.as_str(),
                None,
                None,
                ROUTE_REMOTE_PAIR_CREATE,
                RemoteAccessScope::Admin,
                RemoteAuditScopeDecision::Allowed,
                RemoteAuditOutcome::Success,
                None,
                None,
            ),
        )?;
        if let Some(event) = extra_audit {
            record_remote_audit_event_in_transaction(&transaction, event)?;
        }
        let stored =
            load_remote_pairing_by_hash(&transaction, record.code_hash.as_storage_value())?
                .ok_or_else(|| db_error("remote pairing insert did not persist row"))?;
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit remote pairing create: {error}")))?;
        Ok(stored)
    }

    fn claim_remote_pairing_code(
        &self,
        code: &str,
        claim: &RemotePairingClaimRequest,
        now: &str,
    ) -> Result<RemotePairingClaimedClient, RemotePairingClaimCodeError> {
        validate_pairing_audit_event_id(claim.audit_event_id.as_str())
            .map_err(RemotePairingClaimCodeError::pairing)?;
        if let Err(error) = validate_pairing_domain(&claim.expected_domain, &claim.claimed_domain) {
            return Err(reject_claim(
                self,
                claim,
                now,
                ROUTE_REMOTE_PAIR_DOMAIN,
                error,
            ));
        }

        let code_hash = match RemotePairingCodeHash::from_code(code) {
            Ok(code_hash) => code_hash,
            Err(error) => {
                return Err(reject_claim(
                    self,
                    claim,
                    now,
                    ROUTE_REMOTE_PAIR_INVALID,
                    error,
                ));
            }
        };
        let Some(pairing) =
            load_remote_pairing_by_hash(self.connection(), code_hash.as_storage_value())
                .map_err(RemotePairingClaimCodeError::store)?
        else {
            return Err(reject_claim(
                self,
                claim,
                now,
                ROUTE_REMOTE_PAIR_UNKNOWN,
                RemotePairingError::UnknownCode,
            ));
        };
        if pairing.revoked_at.is_some() {
            // Checked before expiry so a link withdrawn inside its window says
            // it was revoked rather than blaming the clock, and before the
            // claim check for the same reason: revocation is the live fact.
            return Err(reject_claim(
                self,
                claim,
                now,
                ROUTE_REMOTE_PAIR_REVOKED,
                RemotePairingError::Revoked,
            ));
        }
        if pairing.claimed_at.is_some() {
            return Err(reject_claim(
                self,
                claim,
                now,
                ROUTE_REMOTE_PAIR_REPLAY,
                RemotePairingError::AlreadyClaimed,
            ));
        }
        if pairing_is_expired(&pairing.expires_at, now)
            .map_err(RemotePairingClaimCodeError::store)?
        {
            let error = RemotePairingError::Expired;
            let error_detail = error.to_string();
            self.record_remote_pairing_expiration(pairing.pairing_id.as_str(), now)
                .map_err(RemotePairingClaimCodeError::store)?;
            self.record_remote_audit_event(&RemoteAuditEvent::new(
                claim.audit_event_id.as_str(),
                now,
                claim.request_id.as_deref(),
                Some(claim.client_id.as_str()),
                ROUTE_REMOTE_PAIR_EXPIRE,
                RemoteAccessScope::Read,
                RemoteAuditScopeDecision::Denied,
                RemoteAuditOutcome::Failure,
                claim.remote_addr.as_deref(),
                Some(error_detail.as_str()),
            ))
            .map_err(RemotePairingClaimCodeError::store)?;
            return Err(RemotePairingClaimCodeError::pairing(error));
        }

        let bearer_token = RemoteBearerToken::generate();
        let registration = RemoteClientRegistration::new(
            claim.client_id.as_str(),
            claim.display_name.as_str(),
            claim.platform.as_str(),
            pairing.role,
            &pairing.scopes,
            bearer_token.expose(),
            now,
        )
        .map_err(|error| RemotePairingClaimCodeError::pairing(error.into()))?;
        claim_remote_pairing_in_transaction(self, &pairing, &registration, bearer_token, claim, now)
    }

    fn remote_pairing_minted_by(&self, pairing_id: &str) -> Result<RemotePairingOwner, CliError> {
        let metadata_json: Option<String> = self
            .connection()
            .query_row(
                "SELECT metadata_json FROM remote_pairing_codes WHERE pairing_id = ?1",
                [pairing_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| db_error(format!("load pairing {pairing_id} owner: {error}")))?;
        let Some(metadata_json) = metadata_json else {
            return Ok(RemotePairingOwner::Unknown);
        };
        let metadata = decode_remote_pairing_metadata(&metadata_json)
            .map_err(|error| db_error(format!("read pairing {pairing_id} owner: {error}")))?;
        Ok(metadata
            .minted_by
            .map_or(RemotePairingOwner::Host, RemotePairingOwner::Client))
    }

    fn list_remote_pairing_inventory(
        &self,
        now: &str,
        minted_by: Option<&str>,
    ) -> Result<Vec<RemotePairingInventoryEntry>, CliError> {
        let mut statement = self
            .connection()
            .prepare(&SELECT_REMOTE_PAIRING_INVENTORY_SQL)
            .map_err(|error| db_error(format!("prepare remote pairing inventory: {error}")))?;
        let rows = statement
            .query_map([minted_by], |row| Ok(read_inventory_columns(row)))
            .map_err(|error| db_error(format!("query remote pairing inventory: {error}")))?;

        let mut entries = Vec::new();
        for row in rows {
            let columns =
                row.map_err(|error| db_error(format!("read remote pairing inventory: {error}")))??;
            entries.push(entry_from_columns(columns, now)?);
        }
        Ok(entries)
    }

    fn remote_pairing_claimed_by(&self, client_id: &str) -> Result<Option<String>, CliError> {
        self.connection()
            .query_row(
                "SELECT pairing_id FROM remote_pairing_codes WHERE claimed_client_id = ?1",
                [client_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| db_error(format!("query pairing claimed by client: {error}")))
    }

    fn remote_pairing_inventory_entry(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<Option<RemotePairingInventoryEntry>, CliError> {
        let columns = self
            .connection()
            .query_row(&SELECT_REMOTE_PAIRING_ENTRY_SQL, [pairing_id], |row| {
                Ok(read_inventory_columns(row))
            })
            .optional()
            .map_err(|error| db_error(format!("query remote pairing entry: {error}")))?;

        columns
            .transpose()?
            .map(|columns| entry_from_columns(columns, now))
            .transpose()
    }

    fn load_remote_pairing_status(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<RemotePairingStatus, CliError> {
        let pairing_id = pairing_id.trim();
        if pairing_id.is_empty() {
            return Ok(RemotePairingStatus::Unavailable);
        }
        let row = self
            .connection()
            .query_row(
                "SELECT p.expires_at,
                        p.claimed_at,
                        COALESCE(json_extract(p.metadata_json, '$.revoked_at'), c.revoked_at)
                 FROM remote_pairing_codes p
                 LEFT JOIN remote_clients c ON c.client_id = p.claimed_client_id
                 WHERE p.pairing_id = ?1",
                [pairing_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| db_error(format!("load remote pairing status: {error}")))?;
        let Some((expires_at, claimed_at, revoked_at)) = row else {
            return Ok(RemotePairingStatus::Unavailable);
        };
        if revoked_at.is_some() {
            return Ok(RemotePairingStatus::Revoked);
        }
        if claimed_at.is_some() {
            return Ok(RemotePairingStatus::Claimed);
        }
        if pairing_is_expired(&expires_at, now)? {
            self.record_remote_pairing_expiration(pairing_id, now)?;
            return Ok(RemotePairingStatus::Expired);
        }
        Ok(RemotePairingStatus::Pending)
    }

    fn record_remote_pairing_expiration(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<bool, CliError> {
        let transaction = self
            .connection()
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin remote pairing expiration audit: {error}")))?;
        let changed = transaction
            .execute(
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
                 WHERE pairing_id = ?1
                   AND claimed_at IS NULL
                   AND unixepoch(expires_at) <= unixepoch(?2)",
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

fn claim_remote_pairing_in_transaction(
    db: &DaemonDb,
    pairing: &RemoteStoredPairing,
    registration: &RemoteClientRegistration,
    bearer_token: RemoteBearerToken,
    claim: &RemotePairingClaimRequest,
    now: &str,
) -> Result<RemotePairingClaimedClient, RemotePairingClaimCodeError> {
    let transaction = db
        .connection()
        .unchecked_transaction()
        .map_err(|error| db_error(format!("begin remote pairing claim: {error}")))
        .map_err(RemotePairingClaimCodeError::store)?;
    let client = upsert_remote_client_for_pairing(&transaction, registration)
        .map_err(RemotePairingClaimCodeError::store)?;
    let changed = transaction
        .execute(
            "UPDATE remote_pairing_codes
             SET claimed_at = ?2, claimed_client_id = ?3, claim_remote_addr = ?4
             WHERE pairing_id = ?1
               AND claimed_at IS NULL
               AND json_extract(metadata_json, '$.revoked_at') IS NULL",
            params![
                pairing.pairing_id.as_str(),
                now,
                claim.client_id.as_str(),
                claim.remote_addr.as_deref(),
            ],
        )
        .map_err(|error| {
            db_error(format!(
                "claim remote pairing {}: {error}",
                pairing.pairing_id.as_str()
            ))
        })
        .map_err(RemotePairingClaimCodeError::store)?;
    if changed == 0 {
        let revoked_at = transaction
            .query_row(
                "SELECT json_extract(metadata_json, '$.revoked_at')
                 FROM remote_pairing_codes WHERE pairing_id = ?1",
                [pairing.pairing_id.as_str()],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|error| {
                db_error(format!(
                    "read lost pairing {} claim state: {error}",
                    pairing.pairing_id.as_str()
                ))
            })
            .map_err(RemotePairingClaimCodeError::store)?;
        let (error, route) = if revoked_at.is_some() {
            (RemotePairingError::Revoked, ROUTE_REMOTE_PAIR_REVOKED)
        } else {
            (RemotePairingError::AlreadyClaimed, ROUTE_REMOTE_PAIR_REPLAY)
        };
        let error_detail = error.to_string();
        transaction
            .rollback()
            .map_err(|error| db_error(format!("rollback lost remote pairing claim: {error}")))
            .map_err(RemotePairingClaimCodeError::store)?;
        record_pairing_claim_failure(db, claim, now, route, error_detail.as_str())
            .map_err(RemotePairingClaimCodeError::store)?;
        return Err(RemotePairingClaimCodeError::pairing(error));
    }
    record_remote_audit_event_in_transaction(
        &transaction,
        &RemoteAuditEvent::new(
            claim.audit_event_id.as_str(),
            now,
            claim.request_id.as_deref(),
            Some(claim.client_id.as_str()),
            ROUTE_REMOTE_PAIR_CLAIM,
            RemoteAccessScope::Read,
            RemoteAuditScopeDecision::Allowed,
            RemoteAuditOutcome::Success,
            claim.remote_addr.as_deref(),
            None,
        ),
    )
    .map_err(RemotePairingClaimCodeError::store)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit remote pairing claim: {error}")))
        .map_err(RemotePairingClaimCodeError::store)?;
    Ok(RemotePairingClaimedClient {
        client,
        bearer_token,
        reviews_query: pairing.reviews_query.clone(),
    })
}

/// Records the claim-failure audit and folds any store error into the
/// returned value, so every early-exit branch in `claim_remote_pairing_code`
/// collapses to a single `return Err(reject_claim(...))`.
fn reject_claim(
    db: &DaemonDb,
    claim: &RemotePairingClaimRequest,
    now: &str,
    route: &str,
    error: RemotePairingError,
) -> RemotePairingClaimCodeError {
    let error_detail = error.to_string();
    if let Err(store_error) =
        record_pairing_claim_failure(db, claim, now, route, error_detail.as_str())
    {
        return RemotePairingClaimCodeError::Store(store_error);
    }
    RemotePairingClaimCodeError::Pairing(error)
}

fn record_pairing_claim_failure(
    db: &DaemonDb,
    claim: &RemotePairingClaimRequest,
    now: &str,
    route_or_method: &str,
    error_detail: &str,
) -> Result<(), CliError> {
    db.record_remote_audit_event(&RemoteAuditEvent::new(
        claim.audit_event_id.as_str(),
        now,
        claim.request_id.as_deref(),
        Some(claim.client_id.as_str()),
        route_or_method,
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Denied,
        RemoteAuditOutcome::Failure,
        claim.remote_addr.as_deref(),
        Some(error_detail),
    ))
}
