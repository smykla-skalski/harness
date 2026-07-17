use std::sync::Arc;

use sqlx::{query, query_scalar};
use tokio::sync::Barrier;

use super::test_support::{database, instant};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAutomationWakeEntityKind, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRecoveryReason, TaskBoardAutomationWakeRequest,
};

#[tokio::test]
async fn pending_wake_batch_is_bounded_and_stable_by_sequence() {
    let db = database().await;
    query(
        "WITH RECURSIVE values_to_insert(value) AS (
             SELECT 1 UNION ALL SELECT value + 1 FROM values_to_insert WHERE value < 501
         )
         INSERT INTO task_board_orchestrator_wake_events (
             cause, payload_json, created_at
         )
         SELECT 'recovery', '{\"schema_version\":1,\"reason\":\"startup\"}',
                '2026-07-15T10:00:00+00:00'
         FROM values_to_insert",
    )
    .execute(db.pool())
    .await
    .expect("seed pending wake events");

    let first = db
        .pending_task_board_automation_wake_events(u32::MAX)
        .await
        .expect("load first pending batch");
    let second = db
        .pending_task_board_automation_wake_events(u32::MAX)
        .await
        .expect("load second pending batch");

    assert_eq!(first.len(), 500);
    assert_eq!(first.first().map(|event| event.sequence), Some(1));
    assert_eq!(first.last().map(|event| event.sequence), Some(500));
    assert_eq!(first, second);
    assert!(
        db.pending_task_board_automation_wake_events(0)
            .await
            .expect("load empty pending batch")
            .is_empty()
    );
}

#[tokio::test]
async fn identical_pending_wake_is_deduplicated_without_revision_churn() {
    let db = database().await;
    let request = item_wake("item-neutral", 7);
    let version_before = orchestrator_version(&db).await;
    let barrier = Arc::new(Barrier::new(2));

    let (first, second) = tokio::join!(
        enqueue_after_barrier(db.clone(), request.clone(), Arc::clone(&barrier)),
        enqueue_after_barrier(db.clone(), request.clone(), Arc::clone(&barrier)),
    );
    let first = first.expect("enqueue first wake");
    let second = second.expect("enqueue duplicate wake");

    assert_eq!(first, second);
    assert_eq!(orchestrator_version(&db).await, version_before + 1);
    assert_eq!(pending_sequences(&db).await, vec![first.sequence]);
}

#[tokio::test]
async fn sequence_order_survives_a_backward_wall_clock_adjustment() {
    let db = database().await;
    let first = db
        .enqueue_task_board_automation_wake_event(
            &item_wake("item-first", 1),
            instant("2026-07-15T11:00:00Z"),
        )
        .await
        .expect("enqueue first wake");
    let second = db
        .enqueue_task_board_automation_wake_event(
            &item_wake("item-second", 1),
            instant("2026-07-15T10:59:59Z"),
        )
        .await
        .expect("enqueue wake after clock adjustment");

    assert_eq!((first.sequence, second.sequence), (1, 2));
    assert_eq!(pending_sequences(&db).await, vec![1, 2]);
}

#[tokio::test]
async fn wake_acknowledgement_is_exact_atomic_and_idempotent() {
    let db = database().await;
    let first = enqueue_item(&db, "item-first", 1).await;
    let second = enqueue_item(&db, "item-second", 2).await;
    let third = enqueue_item(&db, "item-third", 3).await;
    let version_before = orchestrator_version(&db).await;

    assert_eq!(
        db.acknowledge_task_board_automation_wake_events(
            &[third, first, first],
            instant("2026-07-15T12:03:00Z"),
        )
        .await
        .expect("acknowledge exact wake set"),
        2
    );
    assert_eq!(pending_sequences(&db).await, vec![second]);
    let version_after = orchestrator_version(&db).await;
    assert_eq!(version_after, version_before + 1);

    assert_eq!(
        db.acknowledge_task_board_automation_wake_events(
            &[first, third],
            instant("2026-07-15T12:04:00Z"),
        )
        .await
        .expect("repeat wake acknowledgement"),
        0
    );
    assert_eq!(orchestrator_version(&db).await, version_after);
    assert!(
        db.acknowledge_task_board_automation_wake_events(
            &[second, 999_999],
            instant("2026-07-15T12:05:00Z"),
        )
        .await
        .is_err()
    );
    assert_eq!(pending_sequences(&db).await, vec![second]);
}

#[tokio::test]
async fn acknowledgement_prunes_old_processed_wakes_to_the_retention_bound() {
    let db = database().await;
    seed_wakes(&db, 502).await;
    let first = (1..=500).collect::<Vec<_>>();
    db.acknowledge_task_board_automation_wake_events(&first, instant("2026-07-15T12:10:00Z"))
        .await
        .expect("acknowledge first batch");
    db.acknowledge_task_board_automation_wake_events(&[501, 502], instant("2026-07-15T12:11:00Z"))
        .await
        .expect("acknowledge final batch");

    let retained = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_orchestrator_wake_events
         WHERE processed_at IS NOT NULL",
    )
    .fetch_one(db.pool())
    .await
    .expect("count retained wakes");
    let oldest = query_scalar::<_, i64>(
        "SELECT MIN(sequence) FROM task_board_orchestrator_wake_events
         WHERE processed_at IS NOT NULL",
    )
    .fetch_one(db.pool())
    .await
    .expect("load oldest retained wake");
    assert_eq!((retained, oldest), (500, 3));
}

#[tokio::test]
async fn malformed_persisted_wake_data_fails_closed() {
    let db = database().await;
    let sequence = enqueue_item(&db, "item-strict", 1).await;

    set_wake_column(&db, sequence, "cause", "invalid_cause").await;
    assert_pending_fails(&db).await;
    set_wake_column(&db, sequence, "cause", "ledger_changed").await;
    set_wake_column(
        &db,
        sequence,
        "payload_json",
        r#"{"schema_version":1,"entity_kind":"item","unexpected":true}"#,
    )
    .await;
    assert_pending_fails(&db).await;
    set_wake_column(
        &db,
        sequence,
        "payload_json",
        r#"{"schema_version":2,"entity_kind":"item"}"#,
    )
    .await;
    assert_pending_fails(&db).await;
    set_wake_column(
        &db,
        sequence,
        "payload_json",
        r#"{"schema_version":1,"entity_kind":"item"}"#,
    )
    .await;
    set_wake_column(&db, sequence, "created_at", "invalid-timestamp").await;
    assert_pending_fails(&db).await;
}

#[tokio::test]
async fn unacknowledged_wake_survives_database_reopen() {
    let db = database().await;
    let path = db.storage_path().to_path_buf();
    let event = db
        .enqueue_task_board_automation_wake_event(&recovery_wake(), instant("2026-07-15T14:00:00Z"))
        .await
        .expect("enqueue durable wake");
    drop(db);

    let reopened = AsyncDaemonDb::connect(&path)
        .await
        .expect("reopen wake database");
    assert_eq!(
        reopened
            .pending_task_board_automation_wake_events(10)
            .await
            .expect("load wake after reopen"),
        vec![event]
    );
}

async fn enqueue_after_barrier(
    db: AsyncDaemonDb,
    request: TaskBoardAutomationWakeRequest,
    barrier: Arc<Barrier>,
) -> Result<crate::task_board::TaskBoardAutomationWakeEvent, crate::errors::CliError> {
    barrier.wait().await;
    db.enqueue_task_board_automation_wake_event(&request, instant("2026-07-15T11:00:00Z"))
        .await
}

fn item_wake(entity_id: &str, revision: u64) -> TaskBoardAutomationWakeRequest {
    TaskBoardAutomationWakeRequest {
        entity_id: Some(entity_id.into()),
        entity_revision: Some(revision),
        payload: TaskBoardAutomationWakePayload::ledger_changed(
            TaskBoardAutomationWakeEntityKind::Item,
        ),
    }
}

fn recovery_wake() -> TaskBoardAutomationWakeRequest {
    TaskBoardAutomationWakeRequest {
        entity_id: None,
        entity_revision: None,
        payload: TaskBoardAutomationWakePayload::recovery(
            TaskBoardAutomationWakeRecoveryReason::Startup,
        ),
    }
}

async fn enqueue_item(db: &AsyncDaemonDb, entity_id: &str, revision: u64) -> u64 {
    db.enqueue_task_board_automation_wake_event(
        &item_wake(entity_id, revision),
        instant("2026-07-15T12:00:00Z"),
    )
    .await
    .expect("enqueue item wake")
    .sequence
}

async fn seed_wakes(db: &AsyncDaemonDb, count: i64) {
    query(
        "WITH RECURSIVE values_to_insert(value) AS (
             SELECT 1 UNION ALL SELECT value + 1 FROM values_to_insert WHERE value < ?1
         )
         INSERT INTO task_board_orchestrator_wake_events (
             cause, entity_id, entity_revision, payload_json, created_at
         )
         SELECT 'ledger_changed', 'item-' || value, value,
                '{\"schema_version\":1,\"entity_kind\":\"item\"}',
                '2026-07-15T12:00:00+00:00'
         FROM values_to_insert",
    )
    .bind(count)
    .execute(db.pool())
    .await
    .expect("seed wake rows");
}

async fn pending_sequences(db: &AsyncDaemonDb) -> Vec<u64> {
    db.pending_task_board_automation_wake_events(500)
        .await
        .expect("load pending wake sequences")
        .into_iter()
        .map(|event| event.sequence)
        .collect()
}

async fn orchestrator_version(db: &AsyncDaemonDb) -> i64 {
    query_scalar::<_, i64>(
        "SELECT COALESCE((SELECT version FROM change_tracking WHERE scope = ?1), 0)",
    )
    .bind(super::super::ORCHESTRATOR_CHANGE_SCOPE)
    .fetch_one(db.pool())
    .await
    .expect("load orchestrator change version")
}

async fn set_wake_column(db: &AsyncDaemonDb, sequence: u64, column: &str, value: &str) {
    let sql = match column {
        "cause" => "UPDATE task_board_orchestrator_wake_events SET cause = ?2 WHERE sequence = ?1",
        "payload_json" => {
            "UPDATE task_board_orchestrator_wake_events SET payload_json = ?2 WHERE sequence = ?1"
        }
        "created_at" => {
            "UPDATE task_board_orchestrator_wake_events SET created_at = ?2 WHERE sequence = ?1"
        }
        _ => panic!("unsupported wake fixture column"),
    };
    query(sql)
        .bind(i64::try_from(sequence).expect("stored sequence"))
        .bind(value)
        .execute(db.pool())
        .await
        .expect("update wake fixture");
}

async fn assert_pending_fails(db: &AsyncDaemonDb) {
    assert!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .is_err()
    );
}
