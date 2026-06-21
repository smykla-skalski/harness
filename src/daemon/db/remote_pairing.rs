#![cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "remote pairing storage is wired by the pairing HTTP phase"
    )
)]

use chrono::{DateTime, Utc};
use rusqlite::{params, types::Type};

use super::{db_error, CliError, DaemonDb, OptionalExtension};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    parse_remote_role, parse_remote_scope, RemoteAuditEvent, RemoteAuditOutcome,
    RemoteAuditScopeDecision, RemoteBearerToken, RemoteClientRegistration,
};
use crate::daemon::remote_pairing::{
    validate_pairing_domain, RemotePairingClaimRequest, RemotePairingClaimedClient,
    RemotePairingCodeHash, RemotePairingError, RemotePairingRecord, RemoteStoredPairing,
};

const INSERT_REMOTE_PAIRING_SQL: &str = "
INSERT INTO remote_pairing_codes (
    pairing_id, code_hash, role, scopes_json, created_at, expires_at,
    claimed_at, claimed_client_id, claim_remote_addr, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, NULL, '{}')";

const SELECT_REMOTE_PAIRING_BY_HASH_SQL: &str = "
SELECT pairing_id, code_hash, role, scopes_json, created_at, expires_at,
       claimed_at, claimed_client_id, claim_remote_addr
FROM remote_pairing_codes
WHERE code_hash = ?1";

impl DaemonDb {
    /// Persist a one-time remote pairing code hash.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or scope serialization failures.
    pub(crate) fn create_remote_pairing_code(
        &self,
        record: &RemotePairingRecord,
        audit_event_id: &str,
    ) -> Result<RemoteStoredPairing, CliError> {
        let scopes_json = scopes_to_json(&record.scopes)?;
        self.conn
            .execute(
                INSERT_REMOTE_PAIRING_SQL,
                params![
                    record.pairing_id.as_str(),
                    record.code_hash.as_storage_value(),
                    record.role.as_str(),
                    scopes_json,
                    record.created_at.as_str(),
                    record.expires_at.as_str(),
                ],
            )
            .map_err(|error| {
                db_error(format!(
                    "insert remote pairing {}: {error}",
                    record.pairing_id.as_str()
                ))
            })?;
        self.record_remote_audit_event(&RemoteAuditEvent::new(
            audit_event_id,
            record.created_at.as_str(),
            None,
            None,
            "remote.pair.create",
            RemoteAccessScope::Admin,
            RemoteAuditScopeDecision::Allowed,
            RemoteAuditOutcome::Success,
            None,
            None,
        ))?;
        self.remote_pairing_by_hash(record.code_hash.as_storage_value())?
            .ok_or_else(|| db_error("remote pairing insert did not persist row"))
    }

    /// Claim a valid one-time remote pairing code and create a remote client.
    ///
    /// # Errors
    /// Returns [`CliError`] when the claim is invalid, expired, already used, or
    /// persistence fails.
    pub(crate) fn claim_remote_pairing_code(
        &self,
        code: &str,
        claim: &RemotePairingClaimRequest,
        now: &str,
    ) -> Result<RemotePairingClaimedClient, CliError> {
        if let Err(error) = validate_pairing_domain(&claim.expected_domain, &claim.claimed_domain) {
            let error_detail = error.to_string();
            self.record_pairing_claim_failure(claim, now, error_detail.as_str())?;
            return Err(db_error(error_detail));
        }

        let code_hash =
            RemotePairingCodeHash::from_code(code).map_err(|error| db_error(error.to_string()))?;
        let Some(pairing) = self.remote_pairing_by_hash(code_hash.as_storage_value())? else {
            let error_detail = RemotePairingError::UnknownCode.to_string();
            self.record_pairing_claim_failure(claim, now, error_detail.as_str())?;
            return Err(db_error(error_detail));
        };
        if pairing.claimed_at.is_some() {
            let error_detail = RemotePairingError::AlreadyClaimed.to_string();
            self.record_pairing_claim_failure(claim, now, error_detail.as_str())?;
            return Err(db_error(error_detail));
        }
        if pairing_is_expired(&pairing.expires_at, now)? {
            let error_detail = RemotePairingError::Expired.to_string();
            self.record_remote_audit_event(&RemoteAuditEvent::new(
                claim.audit_event_id.as_str(),
                now,
                None,
                None,
                "remote.pair.expire",
                RemoteAccessScope::Read,
                RemoteAuditScopeDecision::Denied,
                RemoteAuditOutcome::Failure,
                claim.remote_addr.as_deref(),
                Some(error_detail.as_str()),
            ))?;
            return Err(db_error(error_detail));
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
        .map_err(|error| db_error(error.to_string()))?;
        let client = self.register_remote_client(&registration)?;
        let changed = self
            .conn
            .execute(
                "UPDATE remote_pairing_codes
                 SET claimed_at = ?2, claimed_client_id = ?3, claim_remote_addr = ?4
                 WHERE pairing_id = ?1 AND claimed_at IS NULL",
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
            })?;
        if changed == 0 {
            let error_detail = RemotePairingError::AlreadyClaimed.to_string();
            self.delete_lost_pairing_claim_client(claim.client_id.as_str(), now)?;
            self.record_pairing_claim_failure(claim, now, error_detail.as_str())?;
            return Err(db_error(error_detail));
        }
        self.record_remote_audit_event(&RemoteAuditEvent::new(
            claim.audit_event_id.as_str(),
            now,
            None,
            Some(claim.client_id.as_str()),
            "remote.pair.claim",
            RemoteAccessScope::Read,
            RemoteAuditScopeDecision::Allowed,
            RemoteAuditOutcome::Success,
            claim.remote_addr.as_deref(),
            None,
        ))?;
        Ok(RemotePairingClaimedClient {
            client,
            bearer_token,
        })
    }

    fn remote_pairing_by_hash(
        &self,
        code_hash: &str,
    ) -> Result<Option<RemoteStoredPairing>, CliError> {
        self.conn
            .query_row(
                SELECT_REMOTE_PAIRING_BY_HASH_SQL,
                [code_hash],
                remote_pairing_from_row,
            )
            .optional()
            .map_err(|error| db_error(format!("load remote pairing by hash: {error}")))
    }

    fn record_pairing_claim_failure(
        &self,
        claim: &RemotePairingClaimRequest,
        now: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        self.record_remote_audit_event(&RemoteAuditEvent::new(
            claim.audit_event_id.as_str(),
            now,
            None,
            None,
            "remote.pair.claim",
            RemoteAccessScope::Read,
            RemoteAuditScopeDecision::Denied,
            RemoteAuditOutcome::Failure,
            claim.remote_addr.as_deref(),
            Some(error_detail),
        ))
    }

    fn delete_lost_pairing_claim_client(
        &self,
        client_id: &str,
        created_at: &str,
    ) -> Result<(), CliError> {
        self.conn
            .execute(
                "DELETE FROM remote_clients
                 WHERE client_id = ?1
                   AND created_at = ?2
                   AND last_seen_at IS NULL
                   AND revoked_at IS NULL
                   AND rotated_at IS NULL",
                params![client_id, created_at],
            )
            .map_err(|error| {
                db_error(format!(
                    "delete lost remote pairing claim client {client_id}: {error}"
                ))
            })?;
        Ok(())
    }
}

fn remote_pairing_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RemoteStoredPairing> {
    let role_label = row.get::<_, String>(2)?;
    let scopes_json = row.get::<_, String>(3)?;
    let role = parse_remote_role(&role_label).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            2,
            Type::Text,
            format!("unknown remote pairing role '{role_label}'").into(),
        )
    })?;
    let scopes = scopes_from_json(&scopes_json)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(3, Type::Text, error.into()))?;
    let code_hash = RemotePairingCodeHash::try_from_storage_value(row.get::<_, String>(1)?)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(1, Type::Text, error.into()))?;
    Ok(RemoteStoredPairing {
        pairing_id: row.get(0)?,
        code_hash,
        role,
        scopes,
        created_at: row.get(4)?,
        expires_at: row.get(5)?,
        claimed_at: row.get(6)?,
        claimed_client_id: row.get(7)?,
        claim_remote_addr: row.get(8)?,
    })
}

fn scopes_to_json(scopes: &[RemoteAccessScope]) -> Result<String, CliError> {
    let labels = scopes
        .iter()
        .map(|scope| scope.as_str())
        .collect::<Vec<_>>();
    serde_json::to_string(&labels)
        .map_err(|error| db_error(format!("serialize remote pairing scopes: {error}")))
}

fn scopes_from_json(value: &str) -> Result<Vec<RemoteAccessScope>, String> {
    let labels = serde_json::from_str::<Vec<String>>(value)
        .map_err(|error| format!("parse remote pairing scopes: {error}"))?;
    labels
        .iter()
        .map(|label| {
            parse_remote_scope(label)
                .ok_or_else(|| format!("unknown remote pairing scope '{label}'"))
        })
        .collect()
}

fn pairing_is_expired(expires_at: &str, now: &str) -> Result<bool, CliError> {
    let expires_at = DateTime::parse_from_rfc3339(expires_at)
        .map_err(|error| db_error(format!("parse remote pairing expiry: {error}")))?
        .with_timezone(&Utc);
    let now = DateTime::parse_from_rfc3339(now)
        .map_err(|error| db_error(format!("parse remote pairing claim time: {error}")))?
        .with_timezone(&Utc);
    Ok(expires_at <= now)
}
