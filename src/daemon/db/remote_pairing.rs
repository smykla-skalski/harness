#![cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "remote pairing storage is wired by the pairing HTTP phase"
    )
)]

use chrono::{DateTime, Utc};
use rusqlite::{params, types::Type};

use super::{CliError, Connection, DaemonDb, OptionalExtension, db_error};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteBearerToken,
    RemoteClientRegistration, RemoteStoredClient, parse_remote_role, parse_remote_scope,
};
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingClaimedClient, RemotePairingCodeHash,
    RemotePairingError, RemotePairingRecord, RemoteStoredPairing, validate_pairing_audit_event_id,
    validate_pairing_domain,
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

const INSERT_PAIRING_REMOTE_CLIENT_SQL: &str = "
INSERT INTO remote_clients (
    client_id, display_name, platform, role, scopes_json, token_hash, token_hint,
    created_at, last_seen_at, revoked_at, rotated_at, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, NULL, '{}')";

const INSERT_PAIRING_REMOTE_AUDIT_EVENT_SQL: &str = "
INSERT INTO remote_audit_events (
    event_id, recorded_at, request_id, client_id, route_or_method, scope,
    scope_decision, outcome, remote_addr, error_detail, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, '{}')";

const ROUTE_REMOTE_PAIR_CREATE: &str = "remote.pair.create";
const ROUTE_REMOTE_PAIR_CLAIM: &str = "remote.pair.claim";
const ROUTE_REMOTE_PAIR_DOMAIN: &str = "remote.pair.domain";
const ROUTE_REMOTE_PAIR_EXPIRE: &str = "remote.pair.expire";
const ROUTE_REMOTE_PAIR_INVALID: &str = "remote.pair.invalid";
const ROUTE_REMOTE_PAIR_REPLAY: &str = "remote.pair.replay";
const ROUTE_REMOTE_PAIR_UNKNOWN: &str = "remote.pair.unknown";

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
        validate_pairing_audit_event_id(audit_event_id)
            .map_err(|error| db_error(error.to_string()))?;
        let scopes_json = scopes_to_json(&record.scopes)?;
        let transaction = self
            .conn
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
                ],
            )
            .map_err(|error| {
                db_error(format!(
                    "insert remote pairing {}: {error}",
                    record.pairing_id.as_str()
                ))
            })?;
        record_remote_audit_event_for_pairing(
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
        let stored =
            load_remote_pairing_by_hash(&transaction, record.code_hash.as_storage_value())?
                .ok_or_else(|| db_error("remote pairing insert did not persist row"))?;
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit remote pairing create: {error}")))?;
        Ok(stored)
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
        validate_pairing_audit_event_id(claim.audit_event_id.as_str())
            .map_err(|error| db_error(error.to_string()))?;
        if let Err(error) = validate_pairing_domain(&claim.expected_domain, &claim.claimed_domain) {
            let error_detail = error.to_string();
            self.record_pairing_claim_failure(
                claim,
                now,
                ROUTE_REMOTE_PAIR_DOMAIN,
                error_detail.as_str(),
            )?;
            return Err(db_error(error_detail));
        }

        let code_hash = match RemotePairingCodeHash::from_code(code) {
            Ok(code_hash) => code_hash,
            Err(error) => {
                let error_detail = error.to_string();
                self.record_pairing_claim_failure(
                    claim,
                    now,
                    ROUTE_REMOTE_PAIR_INVALID,
                    error_detail.as_str(),
                )?;
                return Err(db_error(error_detail));
            }
        };
        let Some(pairing) = self.remote_pairing_by_hash(code_hash.as_storage_value())? else {
            let error_detail = RemotePairingError::UnknownCode.to_string();
            self.record_pairing_claim_failure(
                claim,
                now,
                ROUTE_REMOTE_PAIR_UNKNOWN,
                error_detail.as_str(),
            )?;
            return Err(db_error(error_detail));
        };
        if pairing.claimed_at.is_some() {
            let error_detail = RemotePairingError::AlreadyClaimed.to_string();
            self.record_pairing_claim_failure(
                claim,
                now,
                ROUTE_REMOTE_PAIR_REPLAY,
                error_detail.as_str(),
            )?;
            return Err(db_error(error_detail));
        }
        if pairing_is_expired(&pairing.expires_at, now)? {
            let error_detail = RemotePairingError::Expired.to_string();
            self.record_remote_audit_event(&RemoteAuditEvent::new(
                claim.audit_event_id.as_str(),
                now,
                None,
                Some(claim.client_id.as_str()),
                ROUTE_REMOTE_PAIR_EXPIRE,
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
        self.claim_remote_pairing_in_transaction(&pairing, &registration, bearer_token, claim, now)
    }

    fn claim_remote_pairing_in_transaction(
        &self,
        pairing: &RemoteStoredPairing,
        registration: &RemoteClientRegistration,
        bearer_token: RemoteBearerToken,
        claim: &RemotePairingClaimRequest,
        now: &str,
    ) -> Result<RemotePairingClaimedClient, CliError> {
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin remote pairing claim: {error}")))?;
        let client = insert_remote_client_for_pairing(&transaction, registration)?;
        let changed = transaction
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
            transaction.rollback().map_err(|error| {
                db_error(format!("rollback lost remote pairing claim: {error}"))
            })?;
            self.record_pairing_claim_failure(
                claim,
                now,
                ROUTE_REMOTE_PAIR_REPLAY,
                error_detail.as_str(),
            )?;
            return Err(db_error(error_detail));
        }
        record_remote_audit_event_for_pairing(
            &transaction,
            &RemoteAuditEvent::new(
                claim.audit_event_id.as_str(),
                now,
                None,
                Some(claim.client_id.as_str()),
                ROUTE_REMOTE_PAIR_CLAIM,
                RemoteAccessScope::Read,
                RemoteAuditScopeDecision::Allowed,
                RemoteAuditOutcome::Success,
                claim.remote_addr.as_deref(),
                None,
            ),
        )?;
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit remote pairing claim: {error}")))?;
        Ok(RemotePairingClaimedClient {
            client,
            bearer_token,
        })
    }

    fn remote_pairing_by_hash(
        &self,
        code_hash: &str,
    ) -> Result<Option<RemoteStoredPairing>, CliError> {
        load_remote_pairing_by_hash(&self.conn, code_hash)
    }

    fn record_pairing_claim_failure(
        &self,
        claim: &RemotePairingClaimRequest,
        now: &str,
        route_or_method: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        self.record_remote_audit_event(&RemoteAuditEvent::new(
            claim.audit_event_id.as_str(),
            now,
            None,
            Some(claim.client_id.as_str()),
            route_or_method,
            RemoteAccessScope::Read,
            RemoteAuditScopeDecision::Denied,
            RemoteAuditOutcome::Failure,
            claim.remote_addr.as_deref(),
            Some(error_detail),
        ))
    }
}

fn insert_remote_client_for_pairing(
    conn: &Connection,
    registration: &RemoteClientRegistration,
) -> Result<RemoteStoredClient, CliError> {
    let scopes_json = scopes_to_json(&registration.scopes)?;
    conn.execute(
        INSERT_PAIRING_REMOTE_CLIENT_SQL,
        params![
            registration.client_id,
            registration.display_name,
            registration.platform,
            registration.role.as_str(),
            scopes_json,
            registration.token_hash.as_storage_value(),
            registration.token_hint,
            registration.created_at,
        ],
    )
    .map_err(|error| {
        db_error(format!(
            "insert remote client {}: {error}",
            registration.client_id.as_str()
        ))
    })?;
    Ok(RemoteStoredClient {
        client_id: registration.client_id.clone(),
        display_name: registration.display_name.clone(),
        platform: registration.platform.clone(),
        role: registration.role,
        scopes: registration.scopes.clone(),
        token_hash: registration.token_hash.clone(),
        token_hint: registration.token_hint.clone(),
        created_at: registration.created_at.clone(),
        last_seen_at: None,
        revoked_at: None,
        rotated_at: None,
    })
}

fn record_remote_audit_event_for_pairing(
    conn: &Connection,
    event: &RemoteAuditEvent,
) -> Result<(), CliError> {
    conn.execute(
        INSERT_PAIRING_REMOTE_AUDIT_EVENT_SQL,
        params![
            event.event_id,
            event.recorded_at,
            event.request_id,
            event.client_id,
            event.route_or_method,
            event.scope.as_str(),
            event.scope_decision.as_str(),
            event.outcome.as_str(),
            event.remote_addr,
            event.error_detail,
        ],
    )
    .map_err(|error| {
        db_error(format!(
            "insert remote audit event {}: {error}",
            event.event_id.as_str()
        ))
    })?;
    Ok(())
}

fn load_remote_pairing_by_hash(
    conn: &Connection,
    code_hash: &str,
) -> Result<Option<RemoteStoredPairing>, CliError> {
    conn.query_row(
        SELECT_REMOTE_PAIRING_BY_HASH_SQL,
        [code_hash],
        remote_pairing_from_row,
    )
    .optional()
    .map_err(|error| db_error(format!("load remote pairing by hash: {error}")))
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
