#![cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "remote identity storage is wired by the auth middleware phase"
    )
)]

use rusqlite::{params, types::Type};

use super::{CliError, Connection, DaemonDb, OptionalExtension, db_error};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
    RemoteStoredAuditEvent, RemoteStoredClient, RemoteTokenHash, parse_remote_role,
    parse_remote_scope, redact_remote_error_detail, remote_token_hint,
};

const INSERT_REMOTE_CLIENT_SQL: &str = "
INSERT INTO remote_clients (
    client_id, display_name, platform, role, scopes_json, token_hash, token_hint,
    created_at, last_seen_at, revoked_at, rotated_at, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, NULL, '{}')";

const UPSERT_PAIRING_REMOTE_CLIENT_SQL: &str = "
INSERT INTO remote_clients (
    client_id, display_name, platform, role, scopes_json, token_hash, token_hint,
    created_at, last_seen_at, revoked_at, rotated_at, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, NULL, '{}')
ON CONFLICT(client_id) DO UPDATE SET
    display_name = excluded.display_name,
    platform = excluded.platform,
    role = excluded.role,
    scopes_json = excluded.scopes_json,
    token_hash = excluded.token_hash,
    token_hint = excluded.token_hint,
    created_at = excluded.created_at,
    last_seen_at = NULL,
    revoked_at = NULL,
    rotated_at = excluded.created_at";

const SELECT_REMOTE_CLIENT_SQL: &str = "
SELECT client_id, display_name, platform, role, scopes_json, token_hash, token_hint,
       created_at, last_seen_at, revoked_at, rotated_at
FROM remote_clients
WHERE client_id = ?1";

const SELECT_REMOTE_CLIENTS_SQL: &str = "
SELECT client_id, display_name, platform, role, scopes_json, token_hash, token_hint,
       created_at, last_seen_at, revoked_at, rotated_at
FROM remote_clients
ORDER BY created_at ASC, client_id ASC";

pub(super) const INSERT_REMOTE_AUDIT_EVENT_SQL: &str = "
INSERT INTO remote_audit_events (
    event_id, recorded_at, request_id, client_id, route_or_method, scope,
    scope_decision, outcome, remote_addr, error_detail, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, '{}')";

pub(super) const MARK_REMOTE_AUDIT_EVENT_FAILED_SQL: &str = "
UPDATE remote_audit_events
SET outcome = 'failure', error_detail = ?2
WHERE event_id = ?1 AND scope_decision = 'allowed'";

impl DaemonDb {
    /// Persist a paired remote client with a hashed bearer token.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or scope serialization failures.
    pub(crate) fn register_remote_client(
        &self,
        registration: &RemoteClientRegistration,
    ) -> Result<RemoteStoredClient, CliError> {
        let scopes_json = scopes_to_json(&registration.scopes)?;
        self.conn
            .execute(
                INSERT_REMOTE_CLIENT_SQL,
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
        self.remote_client(&registration.client_id)?
            .ok_or_else(|| db_error("remote client insert did not persist row"))
    }

    /// Load paired remote clients in stable creation order.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    pub(crate) fn list_remote_clients(&self) -> Result<Vec<RemoteStoredClient>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_REMOTE_CLIENTS_SQL)
            .map_err(|error| db_error(format!("prepare remote clients list: {error}")))?;
        let rows = statement
            .query_map([], remote_client_from_row)
            .map_err(|error| db_error(format!("query remote clients: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read remote client row: {error}")))
    }

    /// Verify a non-revoked remote client's bearer token.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    pub(crate) fn verify_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
    ) -> Result<Option<RemoteStoredClient>, CliError> {
        let Some(client) = self.remote_client(client_id)? else {
            return Ok(None);
        };
        if client.revoked_at.is_some() || !client.token_hash.verify(token) {
            return Ok(None);
        }
        Ok(Some(client))
    }

    /// Refresh an authenticated WebSocket identity from persisted state.
    ///
    /// A missing/revoked client or changed token hash invalidates the session
    /// established with `authenticated`.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    pub(crate) fn validate_remote_client_session(
        &self,
        authenticated: &RemoteStoredClient,
    ) -> Result<Option<RemoteStoredClient>, CliError> {
        let Some(current) = self.remote_client(&authenticated.client_id)? else {
            return Ok(None);
        };
        if current.revoked_at.is_some() || current.token_hash != authenticated.token_hash {
            return Ok(None);
        }
        Ok(Some(current))
    }

    /// Revoke a remote client.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) fn revoke_remote_client(
        &self,
        client_id: &str,
        revoked_at: &str,
    ) -> Result<bool, CliError> {
        let changed = self
            .conn
            .execute(
                "UPDATE remote_clients
                 SET revoked_at = ?2
                 WHERE client_id = ?1 AND revoked_at IS NULL",
                params![client_id, revoked_at],
            )
            .map_err(|error| db_error(format!("revoke remote client {client_id}: {error}")))?;
        Ok(changed > 0)
    }

    /// Rotate a non-revoked remote client's bearer token.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) fn rotate_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
        rotated_at: &str,
    ) -> Result<bool, CliError> {
        if token.trim().is_empty() {
            return Err(db_error("remote client token is required"));
        }
        let token_hash = RemoteTokenHash::from_token(token);
        let changed = self
            .conn
            .execute(
                "UPDATE remote_clients
                 SET token_hash = ?2, token_hint = ?3, rotated_at = ?4
                 WHERE client_id = ?1 AND revoked_at IS NULL",
                params![
                    client_id,
                    token_hash.as_storage_value(),
                    remote_token_hint(token),
                    rotated_at,
                ],
            )
            .map_err(|error| db_error(format!("rotate remote client {client_id}: {error}")))?;
        Ok(changed > 0)
    }

    /// Persist a remote authorization audit event.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) fn record_remote_audit_event(
        &self,
        event: &RemoteAuditEvent,
    ) -> Result<(), CliError> {
        self.conn
            .execute(
                INSERT_REMOTE_AUDIT_EVENT_SQL,
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

    /// Mark a persisted allowed request as failed without creating a duplicate audit row.
    ///
    /// # Errors
    /// Returns [`CliError`] when the row is missing, denied, or cannot be updated.
    pub(crate) fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        let error_detail = redact_remote_error_detail(error_detail);
        let changed = self
            .conn
            .execute(
                MARK_REMOTE_AUDIT_EVENT_FAILED_SQL,
                params![event_id, error_detail],
            )
            .map_err(|error| db_error(format!("mark remote audit {event_id} failed: {error}")))?;
        if changed == 1 {
            return Ok(());
        }
        Err(db_error(format!(
            "mark remote audit {event_id} failed: allowed event not found"
        )))
    }

    /// Load newest remote audit events.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    pub(crate) fn load_remote_audit_events(
        &self,
        limit: u32,
    ) -> Result<Vec<RemoteStoredAuditEvent>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT event_id, recorded_at, request_id, client_id, route_or_method,
                        scope, scope_decision, outcome, remote_addr, error_detail
                 FROM remote_audit_events
                 ORDER BY recorded_at DESC, event_id DESC
                 LIMIT ?1",
            )
            .map_err(|error| db_error(format!("prepare remote audit load: {error}")))?;
        let rows = statement
            .query_map([i64::from(limit)], remote_audit_event_from_row)
            .map_err(|error| db_error(format!("query remote audit events: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read remote audit event row: {error}")))
    }

    fn remote_client(&self, client_id: &str) -> Result<Option<RemoteStoredClient>, CliError> {
        self.conn
            .query_row(
                SELECT_REMOTE_CLIENT_SQL,
                [client_id],
                remote_client_from_row,
            )
            .optional()
            .map_err(|error| db_error(format!("load remote client {client_id}: {error}")))
    }
}

pub(super) fn upsert_remote_client_for_pairing(
    conn: &Connection,
    registration: &RemoteClientRegistration,
) -> Result<RemoteStoredClient, CliError> {
    let scopes_json = scopes_to_json(&registration.scopes)?;
    conn.execute(
        UPSERT_PAIRING_REMOTE_CLIENT_SQL,
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
            "upsert paired remote client {}: {error}",
            registration.client_id.as_str()
        ))
    })?;
    conn.query_row(
        SELECT_REMOTE_CLIENT_SQL,
        [registration.client_id.as_str()],
        remote_client_from_row,
    )
    .map_err(|error| {
        db_error(format!(
            "load paired remote client {}: {error}",
            registration.client_id.as_str()
        ))
    })
}

fn remote_client_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RemoteStoredClient> {
    let role_label = row.get::<_, String>(3)?;
    let scopes_json = row.get::<_, String>(4)?;
    let role = parse_remote_role(&role_label).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            3,
            Type::Text,
            format!("unknown remote role '{role_label}'").into(),
        )
    })?;
    let scopes = scopes_from_json(&scopes_json)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(4, Type::Text, error.into()))?;
    let token_hash = RemoteTokenHash::try_from_storage_value(row.get::<_, String>(5)?)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(5, Type::Text, error.into()))?;
    Ok(RemoteStoredClient {
        client_id: row.get(0)?,
        display_name: row.get(1)?,
        platform: row.get(2)?,
        role,
        scopes,
        token_hash,
        token_hint: row.get(6)?,
        created_at: row.get(7)?,
        last_seen_at: row.get(8)?,
        revoked_at: row.get(9)?,
        rotated_at: row.get(10)?,
    })
}

fn remote_audit_event_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<RemoteStoredAuditEvent> {
    let scope_label = row.get::<_, String>(5)?;
    let decision_label = row.get::<_, String>(6)?;
    let outcome_label = row.get::<_, String>(7)?;
    Ok(RemoteStoredAuditEvent {
        event_id: row.get(0)?,
        recorded_at: row.get(1)?,
        request_id: row.get(2)?,
        client_id: row.get(3)?,
        route_or_method: row.get(4)?,
        scope: parse_scope_at_column(&scope_label, 5)?,
        scope_decision: parse_decision_at_column(&decision_label, 6)?,
        outcome: parse_outcome_at_column(&outcome_label, 7)?,
        remote_addr: row.get(8)?,
        error_detail: row.get(9)?,
    })
}

fn scopes_to_json(scopes: &[RemoteAccessScope]) -> Result<String, CliError> {
    let labels = scopes
        .iter()
        .map(|scope| scope.as_str())
        .collect::<Vec<_>>();
    serde_json::to_string(&labels)
        .map_err(|error| db_error(format!("serialize remote client scopes: {error}")))
}

fn scopes_from_json(value: &str) -> Result<Vec<RemoteAccessScope>, String> {
    let labels = serde_json::from_str::<Vec<String>>(value)
        .map_err(|error| format!("parse remote client scopes: {error}"))?;
    labels
        .iter()
        .map(|label| {
            parse_remote_scope(label)
                .ok_or_else(|| format!("unknown remote client scope '{label}'"))
        })
        .collect()
}

fn parse_scope_at_column(label: &str, column: usize) -> rusqlite::Result<RemoteAccessScope> {
    parse_remote_scope(label).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote audit scope '{label}'").into(),
        )
    })
}

fn parse_decision_at_column(
    label: &str,
    column: usize,
) -> rusqlite::Result<RemoteAuditScopeDecision> {
    match label {
        "allowed" => Ok(RemoteAuditScopeDecision::Allowed),
        "denied" => Ok(RemoteAuditScopeDecision::Denied),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote audit decision '{label}'").into(),
        )),
    }
}

fn parse_outcome_at_column(label: &str, column: usize) -> rusqlite::Result<RemoteAuditOutcome> {
    match label {
        "success" => Ok(RemoteAuditOutcome::Success),
        "failure" => Ok(RemoteAuditOutcome::Failure),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote audit outcome '{label}'").into(),
        )),
    }
}
