use serde_json::Value;
use tempfile::tempdir;

use super::*;
use crate::daemon::protocol::{
    HarnessMonitorAuditEvent, HarnessMonitorAuditEventsRequest, TaskBoardSyncRequest,
};
use crate::errors::CliErrorKind;
use crate::task_board::external::{ExternalSyncBatch, ExternalSyncScopeOutcome};
use crate::task_board::{
    ExternalProvider, ExternalSyncAction, ExternalSyncOperation, TaskBoardSyncSummary,
};

#[tokio::test]
async fn orchestrator_suppresses_successful_scope_poll_without_applied_operations() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let batch = batch(
        Vec::new(),
        vec![ExternalSyncScopeOutcome::success(
            ExternalProvider::GitHub,
            "acme/api".into(),
        )],
        None,
    );
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&batch);
    let result = Ok(sync_summary(batch.operations));

    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &result,
        &metrics,
    )
    .await
    .expect("suppress healthy background audit");

    assert!(
        sync_events(&db).await.is_empty(),
        "healthy background no-op poll must not emit an audit event"
    );
}

#[tokio::test]
async fn requested_partial_batch_records_scope_and_operation_evidence() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let provider_error = CliErrorKind::workflow_io("GitHub scope unavailable").into();
    let batch = batch(
        vec![
            operation(true, ExternalSyncAction::Pull, "task-applied"),
            operation(false, ExternalSyncAction::Conflict, "task-conflict"),
        ],
        vec![
            ExternalSyncScopeOutcome::success(ExternalProvider::GitHub, "acme/api".into()),
            ExternalSyncScopeOutcome::failed(
                ExternalProvider::GitHub,
                "acme/worker".into(),
                &provider_error,
            ),
            ExternalSyncScopeOutcome::backing_off(ExternalProvider::Todoist, "project-42".into()),
        ],
        Some(provider_error),
    );
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&batch);
    let completed = batch.into_completed().expect("one scope succeeded");
    let result = Ok(sync_summary(completed.operations));

    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Requested,
        &result,
        &metrics,
    )
    .await
    .expect("record requested partial audit");

    let events = sync_events(&db).await;
    assert_eq!(events.len(), 1);
    let payload = payload(&events[0]);
    assert_eq!(payload["operation_count"].as_u64(), Some(1));
    assert_eq!(payload["observed_operation_count"].as_u64(), Some(2));
    assert_eq!(payload["applied_operation_count"].as_u64(), Some(1));
    assert_eq!(payload["failed_scope_count"].as_u64(), Some(1));
    assert_eq!(payload["backing_off_scope_count"].as_u64(), Some(1));
    assert_eq!(
        payload["operation_evidence"].as_array().map(Vec::len),
        Some(2)
    );
    assert_eq!(payload["scope_outcomes"].as_array().map(Vec::len), Some(3));
    assert_eq!(
        payload["scope_outcomes"][1]["outcome"].as_str(),
        Some("failed")
    );
    assert_eq!(
        payload["scope_outcomes"][1]["error_code"].as_str(),
        Some("WORKFLOW_IO")
    );
    assert_eq!(
        payload["scope_outcomes"][2]["outcome"].as_str(),
        Some("backing_off")
    );
}

#[tokio::test]
async fn into_completed_error_keeps_partial_batch_evidence() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let provider_error = CliErrorKind::workflow_io("provider rejected request").into();
    let batch = batch(
        vec![operation(true, ExternalSyncAction::Pull, "task-partial")],
        vec![ExternalSyncScopeOutcome::failed(
            ExternalProvider::GitHub,
            "acme/api".into(),
            &provider_error,
        )],
        Some(provider_error),
    );
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&batch);
    let result = batch
        .into_completed()
        .map(|completed| sync_summary(completed.operations));

    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Requested,
        &result,
        &metrics,
    )
    .await
    .expect("record requested failure audit");

    let events = sync_events(&db).await;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].outcome, "failure");
    let payload = payload(&events[0]);
    assert_eq!(payload["operation_count"].as_u64(), Some(1));
    assert_eq!(
        payload["operation_evidence"][0]["board_item_id"].as_str(),
        Some("task-partial")
    );
    assert_eq!(
        payload["scope_outcomes"][0]["scope_id"].as_str(),
        Some("acme/api")
    );
}

#[tokio::test]
async fn orchestrator_records_scope_recovery_without_applied_operations() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let provider_error = CliErrorKind::workflow_io("provider unavailable").into();
    let failed_batch = batch(
        Vec::new(),
        vec![ExternalSyncScopeOutcome::failed(
            ExternalProvider::GitHub,
            "acme/api".into(),
            &provider_error,
        )],
        Some(provider_error),
    );
    let mut failed_metrics = SyncExecutionMetrics::default();
    failed_metrics.capture(&failed_batch);
    let failed_result = failed_batch
        .into_completed()
        .map(|completed| sync_summary(completed.operations));
    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &failed_result,
        &failed_metrics,
    )
    .await
    .expect("record failed scope audit");

    let recovered_batch = batch(
        Vec::new(),
        vec![ExternalSyncScopeOutcome::success(
            ExternalProvider::GitHub,
            "acme/api".into(),
        )],
        None,
    );
    let mut recovered_metrics = SyncExecutionMetrics::default();
    recovered_metrics.capture(&recovered_batch);
    let recovered_result = Ok(sync_summary(recovered_batch.operations));
    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &recovered_result,
        &recovered_metrics,
    )
    .await
    .expect("record recovered scope audit");

    let events = sync_events(&db).await;
    assert_eq!(events.len(), 2);
    let recovery = events
        .iter()
        .map(payload)
        .find(|payload| payload["recovered"].as_bool() == Some(true))
        .expect("scope recovery audit");
    assert_eq!(recovery["recovered"].as_bool(), Some(true));
    assert_eq!(
        recovery["recovery"]["scopes"][0]["provider"].as_str(),
        Some("github")
    );
    assert_eq!(
        recovery["recovery"]["scopes"][0]["scope_id"].as_str(),
        Some("acme/api")
    );
}

#[tokio::test]
async fn orchestrator_records_backoff_once_and_suppresses_unchanged_repeat() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let batch = batch(
        Vec::new(),
        vec![ExternalSyncScopeOutcome::backing_off(
            ExternalProvider::GitHub,
            "acme/api".into(),
        )],
        None,
    );
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&batch);
    let result = Ok(sync_summary(batch.operations));

    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &result,
        &metrics,
    )
    .await
    .expect("record initial backoff audit");
    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &result,
        &metrics,
    )
    .await
    .expect("suppress repeated backoff audit");

    let events = sync_events(&db).await;
    assert_eq!(events.len(), 1);
    assert_eq!(
        payload(&events[0])["scope_outcomes"][0]["outcome"].as_str(),
        Some("backing_off")
    );
}

#[tokio::test]
async fn failed_background_audit_write_does_not_suppress_retry() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let provider_error = CliErrorKind::workflow_io("provider unavailable").into();
    let batch = batch(
        Vec::new(),
        vec![ExternalSyncScopeOutcome::failed(
            ExternalProvider::GitHub,
            "acme/api".into(),
            &provider_error,
        )],
        Some(provider_error),
    );
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&batch);
    let result = batch
        .into_completed()
        .map(|completed| sync_summary(completed.operations));
    sqlx::query(
        "CREATE TRIGGER fail_sync_audit \
         BEFORE INSERT ON audit_events \
         BEGIN SELECT RAISE(FAIL, 'simulated sync audit failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install audit failure trigger");

    let error = record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &result,
        &metrics,
    )
    .await
    .expect_err("audit persistence failure");
    assert!(error.to_string().contains("simulated sync audit failure"));
    sqlx::query("DROP TRIGGER fail_sync_audit")
        .execute(db.pool())
        .await
        .expect("remove audit failure trigger");

    record_request_result(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        &result,
        &metrics,
    )
    .await
    .expect("retry failed audit");

    assert_eq!(sync_events(&db).await.len(), 1);
}

#[tokio::test]
async fn requested_sync_fails_when_audit_event_cannot_be_persisted() {
    let (_dir, db) = open_db().await;
    sqlx::query("DROP TABLE audit_events")
        .execute(db.pool())
        .await
        .expect("drop audit table");

    let error = super::super::sync_task_board_db(&db, &TaskBoardSyncRequest::default())
        .await
        .expect_err("requested sync must fail closed when its audit is lost");

    assert!(
        error.to_string().contains("upsert audit event"),
        "unexpected error: {error}"
    );
}

async fn open_db() -> (tempfile::TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open async database");
    (dir, db)
}

async fn sync_events(db: &AsyncDaemonDb) -> Vec<HarnessMonitorAuditEvent> {
    db.load_audit_events(&HarnessMonitorAuditEventsRequest {
        action_keys: vec!["task_board.sync".into()],
        ..HarnessMonitorAuditEventsRequest::default()
    })
    .await
    .expect("load sync audit events")
    .events
}

fn batch(
    operations: Vec<ExternalSyncOperation>,
    scope_outcomes: Vec<ExternalSyncScopeOutcome>,
    first_provider_failure: Option<crate::errors::CliError>,
) -> ExternalSyncBatch {
    ExternalSyncBatch {
        operations,
        scope_outcomes,
        first_provider_failure,
    }
}

fn sync_summary(operations: Vec<ExternalSyncOperation>) -> TaskBoardSyncSummary {
    TaskBoardSyncSummary {
        total: 0,
        providers: Vec::new(),
        operations,
    }
}

fn operation(
    applied: bool,
    action: ExternalSyncAction,
    board_item_id: &str,
) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider: ExternalProvider::GitHub,
        action,
        board_item_id: Some(board_item_id.into()),
        external_id: Some(format!("external-{board_item_id}")),
        url: Some(format!("https://example.test/{board_item_id}")),
        dry_run: false,
        applied,
        changed_fields: Vec::new(),
        unsupported_fields: Vec::new(),
    }
}

fn payload(event: &HarnessMonitorAuditEvent) -> &Value {
    event.payload_json.as_ref().expect("audit payload")
}
