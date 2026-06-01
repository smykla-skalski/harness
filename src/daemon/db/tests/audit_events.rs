use serde_json::json;
use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn audit_events_round_trip_order_cursor_and_payload() {
    let (_tmp, db) = open_async_db().await;
    for event in [
        sample_audit_event("event-1", "2026-05-31T08:00:00Z"),
        sample_audit_event("event-2", "2026-05-31T09:00:00Z"),
        sample_audit_event("event-3", "2026-05-31T10:00:00Z"),
    ] {
        db.upsert_audit_event(&event)
            .await
            .expect("insert audit event");
    }

    let first_page = db
        .load_audit_events(&daemon_protocol::HarnessMonitorAuditEventsRequest {
            limit: Some(2),
            ..Default::default()
        })
        .await
        .expect("load first audit page");

    assert_eq!(event_ids(&first_page.events), vec!["event-3", "event-2"]);
    assert!(first_page.has_older);
    assert_eq!(
        first_page.next_cursor.as_deref(),
        Some("2026-05-31T09:00:00Z|event-2")
    );
    assert_eq!(
        first_page.events[0].payload_json.as_ref(),
        Some(&json!({ "event": "event-3", "secret": "redacted" }))
    );

    let second_page = db
        .load_audit_events(&daemon_protocol::HarnessMonitorAuditEventsRequest {
            before: first_page.next_cursor,
            limit: Some(2),
            ..Default::default()
        })
        .await
        .expect("load second audit page");

    assert_eq!(event_ids(&second_page.events), vec!["event-1"]);
    assert!(!second_page.has_older);
    assert!(second_page.next_cursor.is_none());
}

#[tokio::test]
async fn audit_events_filter_by_indexed_facets_subject_date_and_search() {
    let (_tmp, db) = open_async_db().await;
    let mut approved = sample_audit_event("github-approve", "2026-05-31T09:00:00Z");
    approved.source = "github".into();
    approved.category = "reviews".into();
    approved.severity = "info".into();
    approved.outcome = "success".into();
    approved.action_key = Some("reviews.approve".into());
    approved.subject = Some("PR #7".into());
    approved.title = "Approved review".into();
    approved.summary = "Approved pull request".into();

    let mut failed_merge = sample_audit_event("github-merge", "2026-05-31T10:00:00Z");
    failed_merge.source = "github".into();
    failed_merge.category = "reviews".into();
    failed_merge.severity = "error".into();
    failed_merge.outcome = "failure".into();
    failed_merge.action_key = Some("reviews.merge".into());
    failed_merge.subject = Some("PR #7".into());
    failed_merge.title = "Merge failed".into();
    failed_merge.summary = "Merge blocked by conflict".into();

    let mut supervisor = sample_audit_event("supervisor-warn", "2026-05-31T11:00:00Z");
    supervisor.source = "supervisor".into();
    supervisor.category = "decision".into();
    supervisor.severity = "warning".into();
    supervisor.outcome = "deferred".into();
    supervisor.action_key = Some("supervisor.wait".into());
    supervisor.subject = Some("session-1".into());
    supervisor.summary = "Waiting for worker".into();

    for event in [approved, failed_merge, supervisor] {
        db.upsert_audit_event(&event)
            .await
            .expect("insert audit event");
    }

    let filtered = db
        .load_audit_events(&daemon_protocol::HarnessMonitorAuditEventsRequest {
            limit: Some(10),
            date_range: Some(daemon_protocol::HarnessMonitorAuditDateRange {
                start: Some("2026-05-31T09:30:00Z".into()),
                end: Some("2026-05-31T10:30:00Z".into()),
            }),
            sources: vec!["github".into()],
            categories: vec!["reviews".into()],
            severities: vec!["error".into()],
            outcomes: vec!["failure".into()],
            action_keys: vec!["reviews.merge".into()],
            subject: Some("PR #7".into()),
            search_text: Some("conflict".into()),
            ..Default::default()
        })
        .await
        .expect("load filtered audit events");

    assert_eq!(event_ids(&filtered.events), vec!["github-merge"]);
    assert!(!filtered.has_older);
}

#[tokio::test]
async fn audit_events_upsert_replaces_existing_row() {
    let (_tmp, db) = open_async_db().await;
    let mut event = sample_audit_event("event-upsert", "2026-05-31T10:00:00Z");
    db.upsert_audit_event(&event)
        .await
        .expect("insert audit event");

    event.recorded_at = "2026-05-31T11:00:00Z".into();
    event.summary = "Updated summary".into();
    event.related_urls = vec!["https://github.com/example/repo/pull/7".into()];
    db.upsert_audit_event(&event)
        .await
        .expect("replace audit event");

    let response = db
        .load_audit_events(&daemon_protocol::HarnessMonitorAuditEventsRequest {
            limit: Some(10),
            ..Default::default()
        })
        .await
        .expect("load audit events");

    assert_eq!(response.events.len(), 1);
    assert_eq!(response.events[0].recorded_at, "2026-05-31T11:00:00Z");
    assert_eq!(response.events[0].summary, "Updated summary");
    assert_eq!(
        response.events[0].related_urls,
        vec!["https://github.com/example/repo/pull/7"]
    );
}

#[tokio::test]
async fn legacy_daemon_events_diagnostics_still_work_after_audit_schema() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync db");
    sync_db
        .append_daemon_event("2026-05-31T12:00:00Z", "warn", "legacy warning")
        .expect("append legacy daemon event");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async db");
    let legacy_events = async_db
        .load_recent_daemon_events(5)
        .await
        .expect("load legacy daemon events");

    assert_eq!(legacy_events.len(), 1);
    assert_eq!(legacy_events[0].message, "legacy warning");
}

async fn open_async_db() -> (tempfile::TempDir, AsyncDaemonDb) {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    (tmp, db)
}

fn sample_audit_event(id: &str, recorded_at: &str) -> daemon_protocol::HarnessMonitorAuditEvent {
    daemon_protocol::HarnessMonitorAuditEvent {
        id: id.into(),
        recorded_at: recorded_at.into(),
        source: "daemon".into(),
        category: "lifecycle".into(),
        kind: "daemon.started".into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: format!("Audit event {id}"),
        summary: "Daemon event recorded".into(),
        subject: Some("daemon".into()),
        actor: Some("harness-monitor".into()),
        correlation_id: Some("correlation-1".into()),
        action_key: Some("daemon.start".into()),
        payload_json: Some(json!({ "event": id, "secret": "redacted" })),
        legacy_message: None,
        related_urls: Vec::new(),
    }
}

fn event_ids(events: &[daemon_protocol::HarnessMonitorAuditEvent]) -> Vec<&str> {
    events.iter().map(|event| event.id.as_str()).collect()
}
