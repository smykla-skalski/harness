use serde_json::Value;
use sqlx::{Sqlite, Transaction, query};

use crate::daemon::audit_events::AuditEventStore;
use crate::daemon::protocol::HarnessMonitorAuditEvent;

use super::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::db_handle::AsyncDaemonDbHandle;

#[allow(dead_code)]
pub(in crate::daemon::db) const UPSERT_AUDIT_EVENT_SQL: &str = "
INSERT INTO audit_events (
    id, recorded_at, source, category, kind, severity, outcome, title, summary,
    subject, actor, correlation_id, action_key, payload_json, legacy_message, related_urls_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
ON CONFLICT(id) DO UPDATE SET
    recorded_at = excluded.recorded_at,
    source = excluded.source,
    category = excluded.category,
    kind = excluded.kind,
    severity = excluded.severity,
    outcome = excluded.outcome,
    title = excluded.title,
    summary = excluded.summary,
    subject = excluded.subject,
    actor = excluded.actor,
    correlation_id = excluded.correlation_id,
    action_key = excluded.action_key,
    payload_json = excluded.payload_json,
    legacy_message = excluded.legacy_message,
    related_urls_json = excluded.related_urls_json";

const INSERT_AUDIT_EVENT_IF_ABSENT_SQL: &str = "
INSERT INTO audit_events (
    id, recorded_at, source, category, kind, severity, outcome, title, summary,
    subject, actor, correlation_id, action_key, payload_json, legacy_message, related_urls_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
ON CONFLICT(id) DO NOTHING";

async fn write_audit_event(
    db: &AsyncDaemonDb,
    statement: &'static str,
    event: &HarnessMonitorAuditEvent,
    operation: &'static str,
) -> Result<u64, CliError> {
    let payload_json = event.payload_json.as_ref().map(Value::to_string);
    let related_urls_json = serde_json::to_string(&event.related_urls)
        .map_err(|error| db_error(format!("serialize audit related urls: {error}")))?;
    query(statement)
        .bind(&event.id)
        .bind(&event.recorded_at)
        .bind(&event.source)
        .bind(&event.category)
        .bind(&event.kind)
        .bind(&event.severity)
        .bind(&event.outcome)
        .bind(&event.title)
        .bind(&event.summary)
        .bind(event.subject.as_deref())
        .bind(event.actor.as_deref())
        .bind(event.correlation_id.as_deref())
        .bind(event.action_key.as_deref())
        .bind(payload_json.as_deref())
        .bind(event.legacy_message.as_deref())
        .bind(&related_urls_json)
        .execute(db.pool())
        .await
        .map(|result| result.rows_affected())
        .map_err(|error| db_error(format!("{operation} audit event {}: {error}", event.id)))
}

// The only place `AsyncDaemonDb` is named as the recorder's storage
// contract - keeping it here, next to the concrete type, means the
// recorder itself never has to import `db`.
impl AuditEventStore for AsyncDaemonDbHandle {
    async fn upsert_audit_event(&self, event: &HarnessMonitorAuditEvent) -> Result<(), CliError> {
        write_audit_event(&self.0, UPSERT_AUDIT_EVENT_SQL, event, "upsert")
            .await
            .map(|_| ())
    }

    async fn insert_audit_event_if_absent(
        &self,
        event: &HarnessMonitorAuditEvent,
    ) -> Result<bool, CliError> {
        write_audit_event(&self.0, INSERT_AUDIT_EVENT_IF_ABSENT_SQL, event, "insert")
            .await
            .map(|rows| rows == 1)
    }
}

pub(in crate::daemon::db) async fn upsert_audit_event_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    event: &HarnessMonitorAuditEvent,
) -> Result<(), CliError> {
    let payload_json = event.payload_json.as_ref().map(Value::to_string);
    let related_urls_json = serde_json::to_string(&event.related_urls)
        .map_err(|error| db_error(format!("serialize audit related urls: {error}")))?;
    query(UPSERT_AUDIT_EVENT_SQL)
        .bind(&event.id)
        .bind(&event.recorded_at)
        .bind(&event.source)
        .bind(&event.category)
        .bind(&event.kind)
        .bind(&event.severity)
        .bind(&event.outcome)
        .bind(&event.title)
        .bind(&event.summary)
        .bind(event.subject.as_deref())
        .bind(event.actor.as_deref())
        .bind(event.correlation_id.as_deref())
        .bind(event.action_key.as_deref())
        .bind(payload_json.as_deref())
        .bind(event.legacy_message.as_deref())
        .bind(&related_urls_json)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("upsert audit event {}: {error}", event.id)))?;
    Ok(())
}

pub(in crate::daemon::db) async fn insert_audit_event_if_absent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    event: &HarnessMonitorAuditEvent,
) -> Result<bool, CliError> {
    let payload_json = event.payload_json.as_ref().map(Value::to_string);
    let related_urls_json = serde_json::to_string(&event.related_urls)
        .map_err(|error| db_error(format!("serialize audit related urls: {error}")))?;
    query(INSERT_AUDIT_EVENT_IF_ABSENT_SQL)
        .bind(&event.id)
        .bind(&event.recorded_at)
        .bind(&event.source)
        .bind(&event.category)
        .bind(&event.kind)
        .bind(&event.severity)
        .bind(&event.outcome)
        .bind(&event.title)
        .bind(&event.summary)
        .bind(event.subject.as_deref())
        .bind(event.actor.as_deref())
        .bind(event.correlation_id.as_deref())
        .bind(event.action_key.as_deref())
        .bind(payload_json.as_deref())
        .bind(event.legacy_message.as_deref())
        .bind(&related_urls_json)
        .execute(transaction.as_mut())
        .await
        .map(|result| result.rows_affected() == 1)
        .map_err(|error| db_error(format!("insert audit event {}: {error}", event.id)))
}
