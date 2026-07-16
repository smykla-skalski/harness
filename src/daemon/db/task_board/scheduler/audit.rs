use serde_json::{Value, json};
use sqlx::{Sqlite, Transaction};
use uuid::Uuid;

use crate::daemon::db::audit::upsert_audit_event_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{TaskBoardAutomationRunOutcome, TaskBoardAutomationScope};

pub(super) async fn insert_automation_audit(
    transaction: &mut Transaction<'_, Sqlite>,
    event_type: &str,
    run_id: &str,
    scope: &TaskBoardAutomationScope,
    recorded_at: &str,
    payload: Value,
) -> Result<HarnessMonitorAuditEvent, CliError> {
    let event = automation_event(event_type, run_id, scope, recorded_at, payload);
    upsert_audit_event_in_tx(transaction, &event).await?;
    Ok(event)
}

pub(super) fn parse_scope(value: &str, run_id: &str) -> Result<TaskBoardAutomationScope, CliError> {
    serde_json::from_str(value).map_err(|error| {
        db_error(format!(
            "parse task board automation run scope '{run_id}': {error}"
        ))
    })
}

pub(super) fn broadcast_automation_audits(events: &[HarnessMonitorAuditEvent]) {
    for event in events {
        crate::daemon::audit_events::broadcast_audit_event(event);
    }
}

pub(super) const fn terminal_event_type(outcome: TaskBoardAutomationRunOutcome) -> &'static str {
    match outcome {
        TaskBoardAutomationRunOutcome::Completed => "task_board.automation.run.completed",
        TaskBoardAutomationRunOutcome::Noop => "task_board.automation.run.noop",
        TaskBoardAutomationRunOutcome::Partial => "task_board.automation.run.partial",
        TaskBoardAutomationRunOutcome::Failed => "task_board.automation.run.failed",
        TaskBoardAutomationRunOutcome::Cancelled => "task_board.automation.run.cancelled",
    }
}

fn automation_event(
    event_type: &str,
    run_id: &str,
    scope: &TaskBoardAutomationScope,
    recorded_at: &str,
    payload: Value,
) -> HarnessMonitorAuditEvent {
    let descriptor = AuditDescriptor::from_event_type(event_type);
    let details = payload;
    HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: recorded_at.to_owned(),
        source: "taskBoard".into(),
        category: "automation".into(),
        kind: event_type.to_owned(),
        severity: descriptor.severity.into(),
        outcome: descriptor.outcome.into(),
        title: format!("Task Board automation: {event_type}"),
        summary: format!("Automation run {run_id} emitted {event_type}"),
        subject: audit_subject(scope),
        actor: Some("Task Board orchestrator".into()),
        correlation_id: Some(run_id.to_owned()),
        action_key: Some(event_type.to_owned()),
        payload_json: Some(json!({
            "run_id": run_id,
            "scope": scope,
            "details": details,
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    }
}

fn audit_subject(scope: &TaskBoardAutomationScope) -> Option<String> {
    scope
        .item_id
        .clone()
        .or_else(|| scope.repository.clone())
        .or_else(|| scope.provider_scope.clone())
        .or_else(|| {
            scope
                .provider
                .map(|provider| format!("{provider:?}").to_lowercase())
        })
}

struct AuditDescriptor {
    severity: &'static str,
    outcome: &'static str,
}

impl AuditDescriptor {
    fn from_event_type(event_type: &str) -> Self {
        if event_type.contains("fail") || event_type.contains("error") {
            return Self {
                severity: "error",
                outcome: "failure",
            };
        }
        if event_type.contains("cancel") {
            return Self {
                severity: "warning",
                outcome: "cancelled",
            };
        }
        if event_type.ends_with(".partial") {
            return Self {
                severity: "warning",
                outcome: "partial",
            };
        }
        if event_type.contains("defer") || event_type.contains("retry") {
            return Self {
                severity: "info",
                outcome: "deferred",
            };
        }
        Self {
            severity: "info",
            outcome: "success",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_keeps_run_correlation_and_scope() {
        let event = automation_event(
            "task_board.automation.run.completed",
            "run-42",
            &TaskBoardAutomationScope {
                item_id: Some("task-17".into()),
                repository: Some("example/widgets".into()),
                ..TaskBoardAutomationScope::default()
            },
            "2026-07-16T12:00:00Z",
            json!({"mutated": false}),
        );

        assert_eq!(event.correlation_id.as_deref(), Some("run-42"));
        assert_eq!(event.subject.as_deref(), Some("task-17"));
        assert_eq!(event.outcome, "success");
        assert_eq!(
            event.payload_json.unwrap()["scope"]["repository"],
            "example/widgets"
        );
    }

    #[test]
    fn failure_and_retry_events_have_distinct_outcomes() {
        let failure = AuditDescriptor::from_event_type("task_board.automation.phase.failed");
        let retry = AuditDescriptor::from_event_type("task_board.automation.phase.retry");

        assert_eq!(failure.severity, "error");
        assert_eq!(failure.outcome, "failure");
        assert_eq!(retry.outcome, "deferred");
    }

    #[test]
    fn partial_run_has_warning_partial_audit_outcome() {
        let partial = AuditDescriptor::from_event_type("task_board.automation.run.partial");

        assert_eq!(partial.severity, "warning");
        assert_eq!(partial.outcome, "partial");
    }
}
