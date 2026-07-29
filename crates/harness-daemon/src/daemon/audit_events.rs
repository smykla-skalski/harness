use std::sync::{Arc, OnceLock};

use serde_json::{Map, Value};
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::daemon::protocol::{HarnessMonitorAuditEvent, StreamEvent};
use crate::daemon::state;
use crate::workspace::utc_now;
use harness_kernel::errors::CliError;

/// Persistence contract the recorder needs from a db handle.
///
/// Kept to exactly the two operations the recorder calls, and generic over
/// the implementer, so this module never names `db`'s concrete async
/// connection type. `db` implements it once, next to that concrete type
/// (`daemon/db/audit.rs`); every consumer here keeps passing a plain
/// `&AsyncDaemonDb` and the compiler infers the rest.
pub(crate) trait AuditEventStore: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on persistence failure.
    async fn upsert_audit_event(&self, event: &HarnessMonitorAuditEvent) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] on persistence failure.
    async fn insert_audit_event_if_absent(
        &self,
        event: &HarnessMonitorAuditEvent,
    ) -> Result<bool, CliError>;
}

static AUDIT_BROADCAST_SENDER: OnceLock<broadcast::Sender<StreamEvent>> = OnceLock::new();

/// Register the daemon-wide event-stream sender the recorder broadcasts
/// through. `service`'s serve bootstrap calls this with the same sender it
/// seeds its own observe runtime with, so this module never has to reach
/// back into `service` to find it.
pub(crate) fn register_broadcast_sender(sender: broadcast::Sender<StreamEvent>) {
    if AUDIT_BROADCAST_SENDER.set(sender).is_err() {
        tracing::warn!(
            "audit broadcast sender already registered; ignoring duplicate registration"
        );
    }
}

fn broadcast_sender() -> Option<broadcast::Sender<StreamEvent>> {
    AUDIT_BROADCAST_SENDER.get().cloned()
}

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

pub(crate) struct AuditEventRecordDraft {
    pub source: &'static str,
    pub category: &'static str,
    pub kind: &'static str,
    pub severity: &'static str,
    pub outcome: &'static str,
    pub title: String,
    pub summary: String,
    pub subject: Option<String>,
    pub actor: Option<String>,
    pub correlation_id: Option<String>,
    pub action_key: Option<String>,
    pub payload_json: Option<Value>,
    pub legacy_message: Option<String>,
    pub related_urls: Vec<String>,
}

pub(crate) async fn record_audit_result<T, Db: AuditEventStore>(
    async_db: Option<&Arc<Db>>,
    draft: AuditEventDraft,
    result: &Result<T, CliError>,
) {
    let Some(async_db) = async_db else {
        return;
    };

    record_audit_result_in_db(async_db.as_ref(), draft, result).await;
}

pub(crate) async fn record_audit_result_in_db<T, Db: AuditEventStore>(
    async_db: &Db,
    draft: AuditEventDraft,
    result: &Result<T, CliError>,
) {
    let event = audit_event_from_result(draft, result);
    persist_audit_event(async_db, &event).await;
}

pub(crate) async fn record_audit_event<Db: AuditEventStore>(
    async_db: Option<&Arc<Db>>,
    draft: AuditEventRecordDraft,
) {
    let Some(async_db) = async_db else {
        return;
    };

    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: draft.source.to_owned(),
        category: draft.category.to_owned(),
        kind: draft.kind.to_owned(),
        severity: draft.severity.to_owned(),
        outcome: draft.outcome.to_owned(),
        title: draft.title,
        summary: draft.summary,
        subject: draft.subject,
        actor: draft.actor,
        correlation_id: draft.correlation_id,
        action_key: draft.action_key,
        payload_json: draft.payload_json,
        legacy_message: draft.legacy_message,
        related_urls: draft.related_urls,
    };
    persist_audit_event(async_db.as_ref(), &event).await;
}

#[expect(
    clippy::cognitive_complexity,
    reason = "audit persistence branches separately for db and legacy-event fallback"
)]
async fn persist_audit_event<Db: AuditEventStore>(async_db: &Db, event: &HarnessMonitorAuditEvent) {
    match async_db.upsert_audit_event(event).await {
        Ok(()) => broadcast_audit_event(event),
        Err(error) => {
            tracing::warn!(
                error = %error,
                action_key = %event.action_key.as_deref().unwrap_or("unknown"),
                "failed to persist typed audit event"
            );
            state::append_event_best_effort(
                "warn",
                &format!(
                    "typed audit persistence failed for {}: {error}",
                    event.action_key.as_deref().unwrap_or(event.kind.as_str())
                ),
            );
        }
    }
}

pub(crate) async fn persist_audit_event_once_strict<Db: AuditEventStore>(
    async_db: &Db,
    event: &HarnessMonitorAuditEvent,
) -> Result<(), CliError> {
    if async_db.insert_audit_event_if_absent(event).await? {
        broadcast_audit_event(event);
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "audit push broadcasting has explicit early returns for each failure mode"
)]
pub(crate) fn broadcast_audit_event(event: &HarnessMonitorAuditEvent) {
    let Some(sender) = broadcast_sender() else {
        return;
    };
    let Ok(payload) = serde_json::to_value(event) else {
        tracing::warn!(
            action_key = %event.action_key.as_deref().unwrap_or("unknown"),
            "failed to serialize typed audit push event"
        );
        return;
    };
    let push = StreamEvent {
        event: "audit_event".into(),
        recorded_at: event.recorded_at.clone(),
        session_id: None,
        payload,
    };
    let receiver_count = sender.receiver_count();
    let _ = sender.send(push);
    tracing::debug!(
        audit_event_id = %event.id,
        receiver_count,
        "typed audit push event sent"
    );
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
            Some(payload_with_error(draft.payload_json, error)),
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

fn payload_with_error(payload: Option<Value>, error: &CliError) -> Value {
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
    Value::Object(object)
}
