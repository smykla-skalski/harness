use chrono::{DateTime, Duration, Utc};
use sqlx::{query, query_as};

use super::super::super::test_support::database;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAutomationEffectiveState, TaskBoardAutomationWakeEntityKind,
    TaskBoardAutomationWakePayload, TaskBoardAutomationWakeRecoveryReason,
    TaskBoardAutomationWakeRequest,
};

#[tokio::test]
async fn wake_projection_uses_sequence_order_and_is_read_only() {
    let db = database().await;
    let now = Utc::now();
    seed_control(&db, now - Duration::minutes(5)).await;
    let first_processed = enqueue_recovery(&db, now - Duration::minutes(3)).await;
    db.acknowledge_task_board_automation_wake_events(
        &[first_processed.sequence],
        now - Duration::minutes(1),
    )
    .await
    .expect("acknowledge first wake");
    let latest_processed = enqueue_recovery(&db, now - Duration::seconds(50)).await;
    let latest_processed_at = now - Duration::minutes(2);
    db.acknowledge_task_board_automation_wake_events(
        &[latest_processed.sequence],
        latest_processed_at,
    )
    .await
    .expect("acknowledge latest sequence after clock rollback");
    let first_pending_at = now - Duration::seconds(30);
    enqueue_recovery(&db, first_pending_at).await;
    db.enqueue_task_board_automation_wake_event(&item_wake(), now - Duration::minutes(4))
        .await
        .expect("enqueue later sequence after clock rollback");
    let before = fingerprint(&db).await;

    let current = db
        .task_board_automation_snapshot()
        .await
        .expect("build wake snapshot");
    assert_eq!(
        current.effective_state,
        TaskBoardAutomationEffectiveState::Scheduled
    );
    assert_eq!(
        current.next_run_at.as_deref(),
        Some(timestamp(first_pending_at).as_str())
    );
    assert_eq!(
        current.last_reconciliation_at.as_deref(),
        Some(timestamp(latest_processed_at).as_str())
    );
    assert_eq!(current.heartbeat_at, timestamp(latest_processed_at));
    assert!(matches!(current.heartbeat_age_seconds, Some(119..=125)));
    assert_eq!(fingerprint(&db).await, before);
}

#[tokio::test]
async fn snapshot_fails_closed_for_a_malformed_wake() {
    let db = database().await;
    let now = Utc::now();
    seed_control(&db, now).await;
    let wake = enqueue_recovery(&db, now).await;
    query(
        "UPDATE task_board_orchestrator_wake_events
         SET payload_json = '{\"schema_version\":1,\"unexpected\":true}'
         WHERE sequence = ?1",
    )
    .bind(i64::try_from(wake.sequence).expect("stored wake sequence"))
    .execute(db.pool())
    .await
    .expect("corrupt wake payload");

    let error = db
        .task_board_automation_snapshot()
        .await
        .expect_err("malformed wake must fail snapshot decoding");
    assert!(error.to_string().contains("wake payload"));
}

async fn seed_control(db: &AsyncDaemonDb, updated_at: DateTime<Utc>) {
    query(
        "INSERT INTO task_board_orchestrator_control (
            singleton, desired_mode, admission_state, stop_generation, updated_at
         ) VALUES (1, 'step', 'accepting', 0, ?1)",
    )
    .bind(timestamp(updated_at))
    .execute(db.pool())
    .await
    .expect("seed control");
}

async fn enqueue_recovery(
    db: &AsyncDaemonDb,
    created_at: DateTime<Utc>,
) -> crate::task_board::TaskBoardAutomationWakeEvent {
    db.enqueue_task_board_automation_wake_event(&recovery_wake(), created_at)
        .await
        .expect("enqueue recovery wake")
}

const fn recovery_wake() -> TaskBoardAutomationWakeRequest {
    TaskBoardAutomationWakeRequest {
        entity_id: None,
        entity_revision: None,
        payload: TaskBoardAutomationWakePayload::recovery(
            TaskBoardAutomationWakeRecoveryReason::Startup,
        ),
    }
}

fn item_wake() -> TaskBoardAutomationWakeRequest {
    TaskBoardAutomationWakeRequest {
        entity_id: Some("item-sequence".into()),
        entity_revision: Some(1),
        payload: TaskBoardAutomationWakePayload::ledger_changed(
            TaskBoardAutomationWakeEntityKind::Item,
        ),
    }
}

async fn fingerprint(db: &AsyncDaemonDb) -> (i64, i64, Option<String>) {
    query_as(
        "SELECT COUNT(*), COUNT(processed_at), MAX(processed_at)
         FROM task_board_orchestrator_wake_events",
    )
    .fetch_one(db.pool())
    .await
    .expect("load wake fingerprint")
}

fn timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339()
}
