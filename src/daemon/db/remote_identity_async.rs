use sqlx::{Sqlite, Transaction, query};

use super::remote_identity::{
    INSERT_REMOTE_AUDIT_EVENT_SQL, MARK_REMOTE_AUDIT_EVENT_FAILED_SQL,
    PRUNE_REMOTE_AUDIT_EVENTS_SQL, REMOTE_AUDIT_EVENT_RETENTION_LIMIT,
};
use super::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::remote_identity::{RemoteAuditEvent, redact_remote_error_detail};

impl AsyncDaemonDb {
    /// Revoke a remote client and persist its lifecycle audit atomically.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure or an audit/client identity mismatch.
    pub(crate) async fn revoke_remote_client_with_audit(
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
            .execute(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "insert remote revoke audit event {}: {error}",
                    audit.event_id
                ))
            })?;
        prune_remote_audit_events_in_transaction(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote client revoke: {error}")))?;
        Ok(true)
    }

    /// Persist a remote authorization audit without blocking a Tokio worker.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) async fn record_remote_audit_event(
        &self,
        event: &RemoteAuditEvent,
    ) -> Result<(), CliError> {
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
            .execute(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "insert remote audit event {}: {error}",
                    event.event_id
                ))
            })?;
        prune_remote_audit_events_in_transaction(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote audit retention: {error}")))?;
        Ok(())
    }

    /// Enforce the durable remote audit retention bound after reconnecting to
    /// an existing database.
    ///
    /// # Errors
    /// Returns [`CliError`] when the retention transaction cannot complete.
    pub(crate) async fn prune_remote_audit_events(&self) -> Result<u64, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote audit prune: {error}")))?;
        let pruned = prune_remote_audit_events_in_transaction(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote audit prune: {error}")))?;
        Ok(pruned)
    }

    /// Mark a persisted allowed request as failed without blocking a Tokio worker.
    ///
    /// # Errors
    /// Returns [`CliError`] when the row is missing, denied, or cannot be updated.
    pub(crate) async fn mark_remote_audit_event_failed(
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

pub(super) async fn prune_remote_audit_events_in_transaction(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<u64, CliError> {
    query(PRUNE_REMOTE_AUDIT_EVENTS_SQL)
        .bind(REMOTE_AUDIT_EVENT_RETENTION_LIMIT)
        .execute(transaction.as_mut())
        .await
        .map(|result| result.rows_affected())
        .map_err(|error| db_error(format!("prune retained remote audit events: {error}")))
}
