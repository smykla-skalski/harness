//! `db`'s interface onto [`DaemonDb`] and [`AsyncDaemonDb`] for remote client
//! identity, tokens, and their audit trail.
//!
//! `db/remote_identity.rs` keeps this area's SQL and row parsing (its audit
//! retention prune, shared with `db/schema.rs`/`db/async_pool.rs`'s own
//! open/connect paths, lives in `db/audit_event_retention(_async).rs`
//! instead), but the traits and their impls live
//! here, next to the domain code that calls them (`daemon::http::auth`,
//! `daemon::websocket::connection`, `harness-daemon-remote-cli`) rather than
//! inside `db`. `db` doesn't own either type's callers, and an inherent
//! `impl` block for this area could never move into a crate `db` doesn't
//! share with them; a trait this module declares has no such problem, since
//! Rust's orphan rule only needs one of the trait or the implementing type to
//! be local.
//!
//! Two traits, not one, because `DaemonDb` and `AsyncDaemonDb` are different
//! concrete types with disjoint method sets here: `DaemonDb` never persists
//! [`revoke_remote_client_with_audit`](RemoteIdentityQueries::revoke_remote_client_with_audit)'s
//! atomic revoke-plus-audit, and `AsyncDaemonDb` never registers or lists
//! clients synchronously.

use rusqlite::params;
use sqlx::query;

use harness_kernel::errors::CliError;

use crate::daemon::db::audit_event_retention_async::prune_remote_audit_events_in_transaction as prune_remote_audit_events_async_in_transaction;
use crate::daemon::db::db_error;
use crate::daemon::db::remote_identity::{
    INSERT_REMOTE_AUDIT_EVENT_SQL, record_remote_audit_event_in_transaction, remote_client,
    remote_client_from_row, scopes_to_json,
};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

use super::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
    RemoteStoredAuditEvent, RemoteStoredClient, RemoteTokenHash, parse_remote_scope,
    redact_remote_error_detail, remote_token_hint,
};

const MARK_REMOTE_AUDIT_EVENT_FAILED_SQL: &str = "
UPDATE remote_audit_events
SET outcome = 'failure', error_detail = ?2
WHERE event_id = ?1 AND scope_decision = 'allowed'";

/// The async half, backed by [`AsyncDaemonDb`].
pub(crate) trait RemoteIdentityQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on SQL failure or an audit/client identity mismatch.
    async fn revoke_remote_client_with_audit(
        &self,
        client_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    async fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the row is missing, denied, or cannot be updated.
    async fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError>;
}

/// The sync half, backed by [`DaemonDb`].
pub trait RemoteIdentitySyncQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL or scope serialization failures.
    fn register_remote_client(
        &self,
        registration: &RemoteClientRegistration,
    ) -> Result<RemoteStoredClient, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn list_remote_clients(&self) -> Result<Vec<RemoteStoredClient>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn verify_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
    ) -> Result<Option<RemoteStoredClient>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn validate_remote_client_session(
        &self,
        authenticated: &RemoteStoredClient,
    ) -> Result<Option<RemoteStoredClient>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn revoke_remote_client(&self, client_id: &str, revoked_at: &str) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn rotate_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
        rotated_at: &str,
    ) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the retention transaction cannot complete.
    fn prune_remote_audit_events(&self) -> Result<u64, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the row is missing, denied, or cannot be updated.
    fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn load_remote_audit_events(&self, limit: u32)
    -> Result<Vec<RemoteStoredAuditEvent>, CliError>;
}

impl RemoteIdentityQueries for AsyncDaemonDb {
    async fn revoke_remote_client_with_audit(
        &self,
        client_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<bool, CliError> {
        if audit.client_id.as_deref() != Some(client_id) {
            return Err(db_error("remote revoke audit client id mismatch"));
        }
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin remote client revoke transaction: {error}"))
        })?;
        let changed = query(
            "UPDATE remote_clients
             SET revoked_at = ?2
             WHERE client_id = ?1 AND revoked_at IS NULL",
        )
        .bind(client_id)
        .bind(revoked_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("revoke remote client {client_id}: {error}")))?
        .rows_affected();
        if changed != 1 {
            transaction.rollback().await.map_err(|error| {
                db_error(format!("rollback unchanged remote client revoke: {error}"))
            })?;
            return Ok(false);
        }
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
                    "insert remote revoke audit event {}: {error}",
                    audit.event_id
                ))
            })?;
        prune_remote_audit_events_async_in_transaction(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote client revoke: {error}")))?;
        Ok(true)
    }

    async fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote audit retention: {error}")))?;
        query(INSERT_REMOTE_AUDIT_EVENT_SQL)
            .bind(&event.event_id)
            .bind(&event.recorded_at)
            .bind(event.request_id.as_deref())
            .bind(event.client_id.as_deref())
            .bind(&event.route_or_method)
            .bind(event.scope.as_str())
            .bind(event.scope_decision.as_str())
            .bind(event.outcome.as_str())
            .bind(event.remote_addr.as_deref())
            .bind(event.error_detail())
            .bind(event.metadata_json())
            .execute(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "insert remote audit event {}: {error}",
                    event.event_id
                ))
            })?;
        prune_remote_audit_events_async_in_transaction(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote audit retention: {error}")))?;
        Ok(())
    }

    async fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        let error_detail = redact_remote_error_detail(error_detail);
        let changed = query(MARK_REMOTE_AUDIT_EVENT_FAILED_SQL)
            .bind(event_id)
            .bind(error_detail)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("mark remote audit {event_id} failed: {error}")))?
            .rows_affected();
        if changed == 1 {
            return Ok(());
        }
        Err(db_error(format!(
            "mark remote audit {event_id} failed: allowed event not found"
        )))
    }
}

impl RemoteIdentitySyncQueries for DaemonDb {
    fn register_remote_client(
        &self,
        registration: &RemoteClientRegistration,
    ) -> Result<RemoteStoredClient, CliError> {
        let scopes_json = scopes_to_json(&registration.scopes)?;
        self.connection()
            .execute(
                "INSERT INTO remote_clients (
                     client_id, display_name, platform, role, scopes_json, token_hash, token_hint,
                     created_at, last_seen_at, revoked_at, rotated_at, metadata_json
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, NULL, '{}')",
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
        remote_client(self, &registration.client_id)?
            .ok_or_else(|| db_error("remote client insert did not persist row"))
    }

    fn list_remote_clients(&self) -> Result<Vec<RemoteStoredClient>, CliError> {
        let mut statement = self
            .connection()
            .prepare(
                "SELECT client_id, display_name, platform, role, scopes_json, token_hash, \
                 token_hint, created_at, last_seen_at, revoked_at, rotated_at
                 FROM remote_clients
                 ORDER BY created_at ASC, client_id ASC",
            )
            .map_err(|error| db_error(format!("prepare remote clients list: {error}")))?;
        let rows = statement
            .query_map([], remote_client_from_row)
            .map_err(|error| db_error(format!("query remote clients: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read remote client row: {error}")))
    }

    fn verify_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
    ) -> Result<Option<RemoteStoredClient>, CliError> {
        let Some(client) = remote_client(self, client_id)? else {
            return Ok(None);
        };
        if client.revoked_at.is_some() || !client.token_hash.verify(token) {
            return Ok(None);
        }
        Ok(Some(client))
    }

    fn validate_remote_client_session(
        &self,
        authenticated: &RemoteStoredClient,
    ) -> Result<Option<RemoteStoredClient>, CliError> {
        let Some(current) = remote_client(self, &authenticated.client_id)? else {
            return Ok(None);
        };
        if current.revoked_at.is_some() || current.token_hash != authenticated.token_hash {
            return Ok(None);
        }
        Ok(Some(current))
    }

    fn revoke_remote_client(&self, client_id: &str, revoked_at: &str) -> Result<bool, CliError> {
        let changed = self
            .connection()
            .execute(
                "UPDATE remote_clients
                 SET revoked_at = ?2
                 WHERE client_id = ?1 AND revoked_at IS NULL",
                params![client_id, revoked_at],
            )
            .map_err(|error| db_error(format!("revoke remote client {client_id}: {error}")))?;
        Ok(changed > 0)
    }

    fn rotate_remote_client_token(
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
            .connection()
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

    fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError> {
        let transaction = self
            .connection()
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin remote audit retention: {error}")))?;
        record_remote_audit_event_in_transaction(&transaction, event)?;
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit remote audit retention: {error}")))?;
        Ok(())
    }

    fn prune_remote_audit_events(&self) -> Result<u64, CliError> {
        crate::daemon::db::audit_event_retention::prune_remote_audit_events(self)
    }

    fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        let error_detail = redact_remote_error_detail(error_detail);
        let changed = self
            .connection()
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

    fn load_remote_audit_events(
        &self,
        limit: u32,
    ) -> Result<Vec<RemoteStoredAuditEvent>, CliError> {
        let mut statement = self
            .connection()
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

fn parse_scope_at_column(
    label: &str,
    column: usize,
) -> rusqlite::Result<crate::daemon::remote::RemoteAccessScope> {
    parse_remote_scope(label).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            rusqlite::types::Type::Text,
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
            rusqlite::types::Type::Text,
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
            rusqlite::types::Type::Text,
            format!("unknown remote audit outcome '{label}'").into(),
        )),
    }
}
