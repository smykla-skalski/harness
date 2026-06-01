use std::sync::Arc;

use serde_json::{Map, Value};
use uuid::Uuid;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::errors::CliError;
use crate::workspace::utc_now;

pub(crate) struct AuditEventDraft {
    pub source: &'static str,
    pub category: &'static str,
    pub kind: &'static str,
    pub action_key: &'static str,
    pub title: String,
    pub subject: Option<String>,
    pub actor: Option<String>,
    pub payload_json: Option<Value>,
    pub related_urls: Vec<String>,
}

pub(crate) async fn record_audit_result<T>(
    async_db: Option<&Arc<AsyncDaemonDb>>,
    draft: AuditEventDraft,
    result: &Result<T, CliError>,
) {
    let Some(async_db) = async_db else {
        return;
    };

    let event = audit_event_from_result(draft, result);
    if let Err(error) = async_db.upsert_audit_event(&event).await {
        tracing::warn!(
            error = %error,
            action_key = %event.action_key.as_deref().unwrap_or("unknown"),
            "failed to persist typed audit event"
        );
    }
}

fn audit_event_from_result<T>(
    draft: AuditEventDraft,
    result: &Result<T, CliError>,
) -> HarnessMonitorAuditEvent {
    let (severity, outcome, summary, payload_json) = match result {
        Ok(_) => (
            "info".to_owned(),
            "success".to_owned(),
            format!("{} succeeded", draft.title),
            draft.payload_json,
        ),
        Err(error) => (
            "error".to_owned(),
            "failure".to_owned(),
            format!("{} failed: {error}", draft.title),
            payload_with_error(draft.payload_json, error),
        ),
    };

    HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: draft.source.to_owned(),
        category: draft.category.to_owned(),
        kind: draft.kind.to_owned(),
        severity,
        outcome,
        title: draft.title,
        summary,
        subject: draft.subject,
        actor: draft.actor,
        correlation_id: None,
        action_key: Some(draft.action_key.to_owned()),
        payload_json,
        legacy_message: None,
        related_urls: draft.related_urls,
    }
}

fn payload_with_error(payload: Option<Value>, error: &CliError) -> Option<Value> {
    let mut object = match payload {
        Some(Value::Object(object)) => object,
        Some(value) => {
            let mut object = Map::new();
            object.insert("request".to_owned(), value);
            object
        }
        None => Map::new(),
    };
    object.insert("error".to_owned(), Value::String(error.to_string()));
    Some(Value::Object(object))
}
