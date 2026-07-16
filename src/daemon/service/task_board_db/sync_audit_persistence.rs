use serde_json::{Map, Value};
use uuid::Uuid;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{HarnessMonitorAuditEvent, StreamEvent};
use crate::daemon::service::observe_sender;
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::TaskBoardSyncAuditTrigger;

pub(super) async fn persist_sync_audit_result<T>(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    payload_json: Value,
    result: &Result<T, CliError>,
) -> Result<(), CliError> {
    let event = sync_audit_event(trigger, payload_json, result);
    db.upsert_audit_event(&event).await?;
    broadcast_audit_event(&event);
    Ok(())
}

fn sync_audit_event<T>(
    trigger: TaskBoardSyncAuditTrigger,
    payload_json: Value,
    result: &Result<T, CliError>,
) -> HarnessMonitorAuditEvent {
    let title = "Sync task-board providers";
    let (severity, outcome, summary, payload_json) = match result {
        Ok(_) => (
            "info".to_owned(),
            "success".to_owned(),
            format!("{title} succeeded"),
            payload_json,
        ),
        Err(error) => (
            "error".to_owned(),
            "failure".to_owned(),
            format!("{title} failed: {error}"),
            payload_with_error(payload_json, error),
        ),
    };
    HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".to_owned(),
        category: "taskBoardMutation".to_owned(),
        kind: "task_board.sync".to_owned(),
        severity,
        outcome,
        title: title.to_owned(),
        summary,
        subject: None,
        actor: Some(trigger.actor().to_owned()),
        correlation_id: None,
        action_key: Some("task_board.sync".to_owned()),
        payload_json: Some(payload_json),
        legacy_message: None,
        related_urls: Vec::new(),
    }
}

fn payload_with_error(payload: Value, error: &CliError) -> Value {
    let mut object = match payload {
        Value::Object(object) => object,
        value => {
            let mut object = Map::new();
            object.insert("request".to_owned(), value);
            object
        }
    };
    object.insert("error".to_owned(), Value::String(error.to_string()));
    Value::Object(object)
}

fn broadcast_audit_event(event: &HarnessMonitorAuditEvent) {
    let Some(sender) = observe_sender() else {
        return;
    };
    let Some(push) = audit_push(event) else {
        return;
    };
    let receiver_count = sender.receiver_count();
    let _ = sender.send(push);
    tracing::debug!(
        audit_event_id = %event.id,
        receiver_count,
        "typed audit push event sent"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn audit_push(event: &HarnessMonitorAuditEvent) -> Option<StreamEvent> {
    let Ok(payload) = serde_json::to_value(event) else {
        tracing::warn!(
            action_key = "task_board.sync",
            "failed to serialize typed audit push event"
        );
        return None;
    };
    Some(StreamEvent {
        event: "audit_event".into(),
        recorded_at: event.recorded_at.clone(),
        session_id: None,
        payload,
    })
}
