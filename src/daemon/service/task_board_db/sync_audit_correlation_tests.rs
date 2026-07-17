use tempfile::tempdir;

use super::*;
use crate::daemon::protocol::{
    HarnessMonitorAuditEvent, HarnessMonitorAuditEventsRequest, TaskBoardSyncRequest,
};
use crate::errors::CliErrorKind;
use crate::task_board::external::{ExternalSyncBatch, ExternalSyncScopeOutcome};
use crate::task_board::{ExternalProvider, TaskBoardSyncSummary};

#[tokio::test]
async fn each_orchestrator_run_keeps_its_correlated_sync_evidence() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let provider_error = CliErrorKind::workflow_io("provider unavailable").into();
    let batch = ExternalSyncBatch {
        operations: Vec::new(),
        external_create_follow_ups: Vec::new(),
        scope_outcomes: vec![ExternalSyncScopeOutcome::failed(
            ExternalProvider::Todoist,
            "scope-a".into(),
            &provider_error,
        )],
        first_provider_failure: Some(provider_error),
        terminal_error: None,
    };
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&batch);
    let result = batch
        .into_completed()
        .map(|completed| sync_summary(completed.operations));

    record_request_result_with_correlation(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        Some("run-a"),
        &result,
        &metrics,
    )
    .await
    .expect("record initial correlated failure");
    record_request_result_with_correlation(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        Some("run-b"),
        &result,
        &metrics,
    )
    .await
    .expect("record repeated failure for the next run");

    let events = sync_events(&db).await;
    assert_eq!(events.len(), 2);
    let mut correlations = events
        .iter()
        .filter_map(|event| event.correlation_id.as_deref())
        .collect::<Vec<_>>();
    correlations.sort_unstable();
    assert_eq!(correlations, ["run-a", "run-b"]);
}

#[tokio::test]
async fn correlated_stable_noop_uses_background_audit_planning() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let metrics = SyncExecutionMetrics::default();
    let result = Ok(sync_summary(Vec::new()));

    for correlation_id in ["run-noop-a", "run-noop-b"] {
        record_request_result_with_correlation(
            &db,
            &request,
            TaskBoardSyncAuditTrigger::Orchestrator,
            Some(correlation_id),
            &result,
            &metrics,
        )
        .await
        .expect("plan correlated no-op audit");
    }

    assert!(sync_events(&db).await.is_empty());
}

#[tokio::test]
async fn correlated_failure_seeds_scope_recovery_tracking() {
    let (_dir, db) = open_db().await;
    let request = TaskBoardSyncRequest::default();
    let provider_error = CliErrorKind::workflow_io("provider unavailable").into();
    let failed_batch = ExternalSyncBatch {
        operations: Vec::new(),
        external_create_follow_ups: Vec::new(),
        scope_outcomes: vec![ExternalSyncScopeOutcome::failed(
            ExternalProvider::Todoist,
            "scope-a".into(),
            &provider_error,
        )],
        first_provider_failure: Some(provider_error),
        terminal_error: None,
    };
    let mut failed_metrics = SyncExecutionMetrics::default();
    failed_metrics.capture(&failed_batch);
    let failed_result = failed_batch
        .into_completed()
        .map(|completed| sync_summary(completed.operations));
    record_request_result_with_correlation(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        Some("run-failed"),
        &failed_result,
        &failed_metrics,
    )
    .await
    .expect("record correlated failure");

    let recovered_batch = ExternalSyncBatch {
        operations: Vec::new(),
        external_create_follow_ups: Vec::new(),
        scope_outcomes: vec![ExternalSyncScopeOutcome::success(
            ExternalProvider::Todoist,
            "scope-a".into(),
        )],
        first_provider_failure: None,
        terminal_error: None,
    };
    let mut recovered_metrics = SyncExecutionMetrics::default();
    recovered_metrics.capture(&recovered_batch);
    let recovered_result = Ok(sync_summary(recovered_batch.operations));
    record_request_result_with_correlation(
        &db,
        &request,
        TaskBoardSyncAuditTrigger::Orchestrator,
        Some("run-recovered"),
        &recovered_result,
        &recovered_metrics,
    )
    .await
    .expect("record correlated recovery");

    let events = sync_events(&db).await;
    assert_eq!(events.len(), 2);
    let recovered = events
        .iter()
        .find(|event| event.correlation_id.as_deref() == Some("run-recovered"))
        .expect("correlated recovery event");
    let payload = recovered.payload_json.as_ref().expect("recovery payload");
    assert_eq!(payload["recovered"].as_bool(), Some(true));
    assert_eq!(
        payload["recovery"]["scopes"][0]["scope_id"].as_str(),
        Some("scope-a")
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

fn sync_summary(operations: Vec<crate::task_board::ExternalSyncOperation>) -> TaskBoardSyncSummary {
    TaskBoardSyncSummary {
        total: 0,
        providers: Vec::new(),
        operations,
    }
}
