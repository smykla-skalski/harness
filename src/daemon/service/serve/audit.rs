use std::process::id;
use std::sync::Arc;

use crate::daemon::audit_events::{AuditEventRecordDraft, record_audit_event};
use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;

pub(super) async fn record_daemon_started(
    async_db: Option<&Arc<AsyncDaemonDb>>,
    endpoint: &str,
    sandboxed: bool,
) {
    record_daemon_lifecycle_event(
        async_db,
        "daemon.started",
        "info",
        "success",
        "Daemon started",
        &format!("Daemon listening on {endpoint}"),
        serde_json::json!({
            "endpoint": endpoint,
            "sandboxed": sandboxed,
            "pid": id(),
        }),
    )
    .await;
}

pub(super) async fn record_daemon_stopped(
    async_db: Option<&Arc<AsyncDaemonDb>>,
    serve_result: &Result<(), CliError>,
) {
    let (severity, outcome, summary, payload) = match serve_result {
        Ok(()) => (
            "info",
            "success",
            "Daemon stopped".to_owned(),
            serde_json::json!({ "pid": id() }),
        ),
        Err(error) => (
            "error",
            "failure",
            format!("Daemon stopped after serve failure: {error}"),
            serde_json::json!({
                "pid": id(),
                "error": error.to_string(),
            }),
        ),
    };
    record_daemon_lifecycle_event(
        async_db,
        "daemon.stopped",
        severity,
        outcome,
        "Daemon stopped",
        &summary,
        payload,
    )
    .await;
}

async fn record_daemon_lifecycle_event(
    async_db: Option<&Arc<AsyncDaemonDb>>,
    kind: &'static str,
    severity: &'static str,
    outcome: &'static str,
    title: &'static str,
    summary: &str,
    payload_json: serde_json::Value,
) {
    record_audit_event(
        async_db,
        AuditEventRecordDraft {
            source: "daemon",
            category: "daemonLifecycle",
            kind,
            severity,
            outcome,
            title: title.to_owned(),
            summary: summary.to_owned(),
            subject: Some("daemon".to_owned()),
            actor: Some("Harness Monitor".to_owned()),
            correlation_id: None,
            action_key: Some(kind.to_owned()),
            payload_json: Some(payload_json),
            legacy_message: None,
            related_urls: Vec::new(),
        },
    )
    .await;
}
