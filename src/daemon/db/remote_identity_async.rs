use sqlx::query;

use super::remote_identity::{INSERT_REMOTE_AUDIT_EVENT_SQL, MARK_REMOTE_AUDIT_EVENT_FAILED_SQL};
use super::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::remote_identity::{RemoteAuditEvent, redact_remote_error_detail};

impl AsyncDaemonDb {
    /// Persist a remote authorization audit without blocking a Tokio worker.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) async fn record_remote_audit_event(
        &self,
        event: &RemoteAuditEvent,
    ) -> Result<(), CliError> {
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
            .execute(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "insert remote audit event {}: {error}",
                    event.event_id
                ))
            })?;
        Ok(())
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
