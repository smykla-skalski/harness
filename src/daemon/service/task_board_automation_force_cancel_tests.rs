use super::task_board_automation_force_cancel::force_cancel_task_board_automation_db;
use crate::daemon::db::{
    accept_remote_controller, claim_remote_controller, remote_controller_fixture,
    seed_cancelable_controller_targets,
};
use crate::daemon::protocol::{
    HarnessMonitorAuditEventsRequest, TaskBoardAutomationForceCancelDisposition,
    TaskBoardAutomationForceCancelRequest,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE,
    TaskBoardAutomationDesiredMode, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRecoveryReason, TaskBoardAutomationWakeRequest, TaskBoardExecutionState,
    TaskBoardItem,
};
const REASON: &str = "operator requested exact remote cancellation";

#[tokio::test]
async fn exact_remote_cancel_persists_one_replayable_pr7_intent() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    assert!(
        fixture
            .db
            .task_board_automation_snapshot()
            .await
            .expect("starting snapshot")
            .cancelable_targets
            .is_empty()
    );
    let claimed = claim_remote_controller(&fixture, &offered).await;
    let before = fixture
        .db
        .task_board_automation_snapshot()
        .await
        .expect("running snapshot");
    let [target] = before.cancelable_targets.as_slice() else {
        panic!("expected one exact running target");
    };
    assert_eq!(target.assignment_id, claimed.assignment_id);
    assert_eq!(target.host_id, claimed.host_id);
    assert_eq!(target.fencing_epoch, claimed.fencing_epoch);
    assert!(!target.cancel_pending);
    let request = TaskBoardAutomationForceCancelRequest {
        target: target.clone(),
        reason: REASON.into(),
        actor: Some("test operator".into()),
    };

    let accepted = force_cancel_task_board_automation_db(&fixture.db, &request)
        .await
        .expect("persist exact cancel intent");
    assert_eq!(
        accepted.disposition,
        TaskBoardAutomationForceCancelDisposition::AcceptedPending
    );
    let after = fixture
        .db
        .task_board_automation_snapshot()
        .await
        .expect("snapshot after accepted cancellation");
    let [pending] = after.cancelable_targets.as_slice() else {
        panic!("pending target remains observable");
    };
    assert!(pending.cancel_pending);
    assert!(pending.has_same_binding(target));

    let stored = fixture
        .db
        .task_board_workflow_execution(&target.execution_id)
        .await
        .expect("load pending workflow")
        .expect("pending workflow exists");
    assert_eq!(
        stored.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert!(
        stored
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE)
    );
    assert_eq!(
        stored
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE)
            .map(String::as_str),
        Some(REASON)
    );

    let replay = force_cancel_task_board_automation_db(&fixture.db, &request)
        .await
        .expect("replay pending cancel intent");
    assert_eq!(
        replay.disposition,
        TaskBoardAutomationForceCancelDisposition::ReplayedPending
    );
    let events = force_cancel_events(&fixture.db).await;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].actor.as_deref(), Some("test operator"));
    assert_eq!(events[0].outcome, "success");
    assert!(
        !serde_json::to_string(&events[0])
            .expect("serialize audit event")
            .contains(REASON),
        "force-cancel reason must stay redacted"
    );
}

#[tokio::test]
async fn stale_exact_target_is_rejected_without_workflow_mutation() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    claim_remote_controller(&fixture, &offered).await;
    let before = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load workflow")
        .expect("workflow exists");
    let mut target = fixture
        .db
        .task_board_automation_cancel_target(&before.execution_id)
        .await
        .expect("load cancel target")
        .expect("cancel target exists");
    target.expected_record_sha256 = "f".repeat(64);

    let error = force_cancel_task_board_automation_db(
        &fixture.db,
        &TaskBoardAutomationForceCancelRequest {
            target,
            reason: REASON.into(),
            actor: Some("test operator".into()),
        },
    )
    .await
    .expect_err("stale target must reject");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(
        fixture
            .db
            .task_board_workflow_execution(&before.execution_id)
            .await
            .expect("reload workflow")
            .expect("workflow exists"),
        before
    );
    let events = force_cancel_events(&fixture.db).await;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].outcome, "rejected");
    assert!(
        !serde_json::to_string(&events[0])
            .expect("serialize rejected audit")
            .contains(REASON)
    );
}

#[tokio::test]
async fn concurrent_identical_cancels_converge_without_rejected_audit() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    claim_remote_controller(&fixture, &offered).await;
    let target = fixture
        .db
        .task_board_automation_cancel_target(&fixture.execution.execution_id)
        .await
        .expect("load cancel target")
        .expect("cancel target exists");
    let request = Arc::new(TaskBoardAutomationForceCancelRequest {
        target,
        reason: REASON.into(),
        actor: Some("test operator".into()),
    });
    let barrier = Arc::new(Barrier::new(3));
    let left = spawn_cancel(
        fixture.db.clone(),
        Arc::clone(&request),
        Arc::clone(&barrier),
    );
    let right = spawn_cancel(fixture.db.clone(), request, Arc::clone(&barrier));
    barrier.wait().await;
    let left = left
        .await
        .expect("join first cancellation")
        .expect("first cancellation");
    let right = right
        .await
        .expect("join second cancellation")
        .expect("second cancellation");
    let dispositions = [left.disposition, right.disposition];
    assert_eq!(
        dispositions
            .iter()
            .filter(|value| **value == TaskBoardAutomationForceCancelDisposition::AcceptedPending)
            .count(),
        1
    );
    assert_eq!(
        dispositions
            .iter()
            .filter(|value| **value == TaskBoardAutomationForceCancelDisposition::ReplayedPending)
            .count(),
        1
    );
    let events = force_cancel_events(&fixture.db).await;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].outcome, "success");
}

#[tokio::test]
async fn audit_insert_failure_rolls_back_cancel_intent() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    claim_remote_controller(&fixture, &offered).await;
    let before = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load workflow before failed audit")
        .expect("workflow exists");
    let target = fixture
        .db
        .task_board_automation_cancel_target(&before.execution_id)
        .await
        .expect("load cancel target")
        .expect("cancel target exists");
    query(
        "CREATE TRIGGER fail_force_cancel_audit
         BEFORE INSERT ON audit_events
         WHEN NEW.action_key = 'task_board.automation.execution.force_cancel'
         BEGIN SELECT RAISE(ABORT, 'forced force-cancel audit failure'); END",
    )
    .execute(fixture.db.pool())
    .await
    .expect("install audit failure trigger");

    force_cancel_task_board_automation_db(
        &fixture.db,
        &TaskBoardAutomationForceCancelRequest {
            target,
            reason: REASON.into(),
            actor: Some("test operator".into()),
        },
    )
    .await
    .expect_err("audit failure must reject force cancel");
    assert_eq!(
        fixture
            .db
            .task_board_workflow_execution(&before.execution_id)
            .await
            .expect("reload workflow after failed audit")
            .expect("workflow exists"),
        before
    );
    assert!(force_cancel_events(&fixture.db).await.is_empty());
}

#[tokio::test]
async fn malformed_snapshot_does_not_reclassify_durable_cancel() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    claim_remote_controller(&fixture, &offered).await;
    let target = fixture
        .db
        .task_board_automation_cancel_target(&fixture.execution.execution_id)
        .await
        .expect("load cancel target")
        .expect("cancel target exists");
    let wake = fixture
        .db
        .enqueue_task_board_automation_wake_event(
            &TaskBoardAutomationWakeRequest {
                entity_id: None,
                entity_revision: None,
                payload: TaskBoardAutomationWakePayload::recovery(
                    TaskBoardAutomationWakeRecoveryReason::Startup,
                ),
            },
            chrono::Utc::now(),
        )
        .await
        .expect("enqueue recovery wake");
    query(
        "UPDATE task_board_orchestrator_wake_events
         SET payload_json = '{\"schema_version\":1,\"unexpected\":true}'
         WHERE sequence = ?1",
    )
    .bind(i64::try_from(wake.sequence).expect("stored wake sequence"))
    .execute(fixture.db.pool())
    .await
    .expect("corrupt wake payload");
    fixture
        .db
        .task_board_automation_snapshot()
        .await
        .expect_err("malformed wake must fail snapshot");

    let response = force_cancel_task_board_automation_db(
        &fixture.db,
        &TaskBoardAutomationForceCancelRequest {
            target,
            reason: REASON.into(),
            actor: Some("test operator".into()),
        },
    )
    .await
    .expect("cancel remains independent of snapshot projection");
    assert_eq!(
        response.disposition,
        TaskBoardAutomationForceCancelDisposition::AcceptedPending
    );
    let events = force_cancel_events(&fixture.db).await;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].outcome, "success");
}

#[tokio::test]
async fn ineligible_first_scan_page_does_not_hide_exact_target() {
    let fixture = remote_controller_fixture(1).await;
    initialize_automation_control(&fixture.db).await;
    let offered = accept_remote_controller(&fixture).await;
    claim_remote_controller(&fixture, &offered).await;
    for index in 0..101 {
        seed_ineligible_remote_execution(&fixture.db, &fixture.execution.execution_id, index).await;
    }

    let snapshot = fixture
        .db
        .task_board_automation_snapshot()
        .await
        .expect("snapshot scans beyond ineligible first page");
    assert_eq!(snapshot.cancelable_targets.len(), 1);
    assert_eq!(
        snapshot.cancelable_targets[0].execution_id,
        fixture.execution.execution_id
    );
    assert!(!snapshot.cancelable_targets_truncated);
}

#[tokio::test]
async fn eligible_remote_cancel_targets_truncate_at_one_hundred() {
    let fixture = remote_controller_fixture(101).await;
    initialize_automation_control(&fixture.db).await;
    seed_cancelable_controller_targets(&fixture, 101).await;

    let snapshot = fixture
        .db
        .task_board_automation_snapshot()
        .await
        .expect("snapshot 101 eligible remote targets");
    assert_eq!(snapshot.cancelable_targets.len(), 100);
    assert!(snapshot.cancelable_targets_truncated);
}

fn spawn_cancel(
    db: crate::daemon::db::AsyncDaemonDb,
    request: Arc<TaskBoardAutomationForceCancelRequest>,
    barrier: Arc<Barrier>,
) -> tokio::task::JoinHandle<
    Result<
        crate::daemon::protocol::TaskBoardAutomationForceCancelResponse,
        crate::errors::CliError,
    >,
> {
    tokio::spawn(async move {
        barrier.wait().await;
        force_cancel_task_board_automation_db(&db, &request).await
    })
}

async fn seed_ineligible_remote_execution(
    db: &crate::daemon::db::AsyncDaemonDb,
    template_execution_id: &str,
    index: usize,
) {
    let item_id = format!("a-hidden-item-{index:03}");
    db.create_task_board_item(TaskBoardItem::new(
        item_id.clone(),
        "Ineligible remote execution".into(),
        "Exercises cancel-target scan pagination".into(),
        "2026-07-19T09:00:00Z".into(),
    ))
    .await
    .expect("create ineligible target item");
    query(
        "INSERT INTO task_board_workflow_executions (
            execution_id, item_id, workflow_kind, phase, state, item_revision,
            configuration_revision, provider_revision, snapshot_json,
            resolved_reviewer_json, host_id, fencing_epoch, available_at, blocked_reason,
            diagnostics_json, resource_ownership_json, created_at, updated_at, completed_at
         ) SELECT ?1, ?2, workflow_kind, phase, state, item_revision,
                  configuration_revision, provider_revision, snapshot_json,
                  resolved_reviewer_json, host_id, fencing_epoch, available_at, blocked_reason,
                  diagnostics_json, resource_ownership_json, created_at, updated_at, completed_at
           FROM task_board_workflow_executions WHERE execution_id = ?3",
    )
    .bind(format!("a-hidden-execution-{index:03}"))
    .bind(item_id)
    .bind(template_execution_id)
    .execute(db.pool())
    .await
    .expect("copy ineligible remote execution");
}

async fn force_cancel_events(
    db: &crate::daemon::db::AsyncDaemonDb,
) -> Vec<crate::daemon::protocol::HarnessMonitorAuditEvent> {
    db.load_audit_events(&HarnessMonitorAuditEventsRequest {
        action_keys: vec!["task_board.automation.execution.force_cancel".into()],
        ..HarnessMonitorAuditEventsRequest::default()
    })
    .await
    .expect("load force-cancel audit events")
    .events
}

async fn initialize_automation_control(db: &crate::daemon::db::AsyncDaemonDb) {
    db.initialize_task_board_automation_control_from_legacy_intent(
        TaskBoardAutomationDesiredMode::Off,
        chrono::Utc::now(),
    )
    .await
    .expect("initialize automation control");
}
use std::sync::Arc;

use sqlx::query;
use tokio::sync::Barrier;
