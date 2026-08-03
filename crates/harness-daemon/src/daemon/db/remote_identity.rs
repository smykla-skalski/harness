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
    RemoteAuditEvent, RemoteClientRegistration, RemoteStoredClient, RemoteTokenHash,
    parse_remote_role, parse_remote_scope,
};

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

pub(crate) const INSERT_REMOTE_AUDIT_EVENT_SQL: &str = "
INSERT INTO remote_audit_events (
    event_id, recorded_at, request_id, client_id, route_or_method, scope,
    scope_decision, outcome, remote_addr, error_detail, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)";

/// Durable cap for remote authorization and lifecycle evidence.
///
/// The cap is intentionally independent of the in-memory unauthenticated
/// admission limiter: it survives process restarts and bounds every remote
/// audit writer, including pairing and lifecycle paths.
pub(crate) const REMOTE_AUDIT_EVENT_RETENTION_LIMIT: i64 = 10_000;

pub(crate) const PRUNE_REMOTE_AUDIT_EVENTS_SQL: &str = "
DELETE FROM remote_audit_events
WHERE event_id IN (
    SELECT event_id
    FROM remote_audit_events
    ORDER BY recorded_at DESC, event_id DESC
    LIMIT -1 OFFSET ?1
)";

/// Loads one remote client by id, the read every write and auth check in this
/// domain funnels through.
///
/// # Errors
/// Returns [`CliError`] on SQL or row parsing failures.
pub(crate) fn remote_client(
    db: &DaemonDb,
    client_id: &str,
) -> Result<Option<RemoteStoredClient>, CliError> {
    db.conn
        .query_row(
            SELECT_REMOTE_CLIENT_SQL,
            [client_id],
            remote_client_from_row,
        )
        .optional()
        .map_err(|error| db_error(format!("load remote client {client_id}: {error}")))
}

/// # Errors
/// Returns [`CliError`] on SQL failure.
pub(crate) fn record_remote_audit_event_in_transaction(
    conn: &Connection,
    event: &RemoteAuditEvent,
) -> Result<(), CliError> {
    insert_remote_audit_event(conn, event)?;
    prune_remote_audit_events_in_transaction(conn)?;
    Ok(())
}

/// # Errors
/// Returns [`CliError`] when the retention transaction cannot complete.
pub(crate) fn prune_remote_audit_events_in_transaction(conn: &Connection) -> Result<u64, CliError> {
    conn.execute(
        PRUNE_REMOTE_AUDIT_EVENTS_SQL,
        [REMOTE_AUDIT_EVENT_RETENTION_LIMIT],
    )
    .map(|pruned| u64::try_from(pruned).unwrap_or(u64::MAX))
    .map_err(|error| db_error(format!("prune retained remote audit events: {error}")))
}

fn insert_remote_audit_event(conn: &Connection, event: &RemoteAuditEvent) -> Result<(), CliError> {
    conn.execute(
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
            event.metadata_json(),
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

/// # Errors
/// Returns [`CliError`] on SQL or scope serialization failures.
pub(crate) fn upsert_remote_client_for_pairing(
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

pub(crate) fn remote_client_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<RemoteStoredClient> {
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

pub(crate) fn scopes_to_json(scopes: &[RemoteAccessScope]) -> Result<String, CliError> {
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
