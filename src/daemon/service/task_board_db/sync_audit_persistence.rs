use serde_json::{Map, Value};
use uuid::Uuid;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{HarnessMonitorAuditEvent, StreamEvent};
use crate::daemon::service::observe_sender;
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::TaskBoardSyncAuditTrigger;
use super::metrics::SyncExecutionMetrics;

const SYNC_AUDIT_TITLE: &str = "Sync task-board providers";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SyncAuditClassification {
    Success,
    PartialFailure {
        failed_scope_count: usize,
        backing_off_scope_count: usize,
    },
    BackingOff {
        scope_count: usize,
    },
    Failure,
}

impl SyncAuditClassification {
    pub(super) fn for_request<T>(
        result: &Result<T, CliError>,
        metrics: &SyncExecutionMetrics,
    ) -> Self {
        if result.is_err() {
            return Self::Failure;
        }
        if metrics.failed_scope_count() > 0 {
            return Self::PartialFailure {
                failed_scope_count: metrics.failed_scope_count(),
                backing_off_scope_count: metrics.backing_off_scope_count(),
            };
        }
        if metrics.all_scopes_backing_off() {
            return Self::BackingOff {
                scope_count: metrics.backing_off_scope_count(),
            };
        }
        Self::Success
    }

    pub(super) fn for_result<T>(result: &Result<T, CliError>) -> Self {
        if result.is_ok() {
            Self::Success
        } else {
            Self::Failure
        }
    }

    fn presentation(self, error: Option<&CliError>) -> AuditPresentation {
        match self {
            Self::Success => AuditPresentation::success(),
            Self::PartialFailure {
                failed_scope_count,
                backing_off_scope_count,
            } => AuditPresentation::partial_failure(failed_scope_count, backing_off_scope_count),
            Self::BackingOff { scope_count } => AuditPresentation::backing_off(scope_count),
            Self::Failure => AuditPresentation::failure(error),
        }
    }
}

pub(super) async fn persist_sync_audit_result<T>(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    payload_json: Value,
    classification: SyncAuditClassification,
    result: &Result<T, CliError>,
) -> Result<(), CliError> {
    let event = sync_audit_event(trigger, payload_json, classification, result);
    db.upsert_audit_event(&event).await?;
    broadcast_audit_event(&event);
    Ok(())
}

fn sync_audit_event<T>(
    trigger: TaskBoardSyncAuditTrigger,
    payload_json: Value,
    classification: SyncAuditClassification,
    result: &Result<T, CliError>,
) -> HarnessMonitorAuditEvent {
    let presentation = classification.presentation(result.as_ref().err());
    let payload_json = match result {
        Ok(_) => payload_json,
        Err(error) => payload_with_error(payload_json, error),
    };
    HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".to_owned(),
        category: "taskBoardMutation".to_owned(),
        kind: "task_board.sync".to_owned(),
        severity: presentation.severity.to_owned(),
        outcome: presentation.outcome.to_owned(),
        title: SYNC_AUDIT_TITLE.to_owned(),
        summary: presentation.summary,
        subject: None,
        actor: Some(trigger.actor().to_owned()),
        correlation_id: None,
        action_key: Some("task_board.sync".to_owned()),
        payload_json: Some(payload_json),
        legacy_message: None,
        related_urls: Vec::new(),
    }
}

struct AuditPresentation {
    severity: &'static str,
    outcome: &'static str,
    summary: String,
}

impl AuditPresentation {
    fn success() -> Self {
        Self {
            severity: "info",
            outcome: "success",
            summary: format!("{SYNC_AUDIT_TITLE} succeeded"),
        }
    }

    fn partial_failure(failed_scope_count: usize, backing_off_scope_count: usize) -> Self {
        let mut details = vec![scope_detail(failed_scope_count, "failed")];
        if backing_off_scope_count > 0 {
            details.push(scope_detail(backing_off_scope_count, "backing-off"));
        }
        Self {
            severity: "warning",
            outcome: "failure",
            summary: format!(
                "{SYNC_AUDIT_TITLE} completed with {}",
                details.join(" and ")
            ),
        }
    }

    fn backing_off(scope_count: usize) -> Self {
        Self {
            severity: "warning",
            outcome: "waiting",
            summary: format!(
                "{SYNC_AUDIT_TITLE} skipped {} while backing off",
                scope_count_label(scope_count)
            ),
        }
    }

    fn failure(error: Option<&CliError>) -> Self {
        let summary = error.map_or_else(
            || format!("{SYNC_AUDIT_TITLE} failed"),
            |error| format!("{SYNC_AUDIT_TITLE} failed: {error}"),
        );
        Self {
            severity: "error",
            outcome: "failure",
            summary,
        }
    }
}

fn scope_detail(count: usize, outcome: &str) -> String {
    format!("{count} {outcome} scope{}", plural_suffix(count))
}

fn scope_count_label(count: usize) -> String {
    format!("{count} scope{}", plural_suffix(count))
}

const fn plural_suffix(count: usize) -> &'static str {
    if count == 1 { "" } else { "s" }
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
