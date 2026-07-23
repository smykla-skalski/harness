use sqlx::query_scalar;
use tempfile::tempdir;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardLanePositionInput, TaskBoardTriageOverrideSetInput,
};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TriageVerdict};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn backlog_item(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item
}

async fn seq(db: &AsyncDaemonDb) -> i64 {
    db.task_board_items_snapshot(None)
        .await
        .expect("snapshot")
        .items_change_seq
}

async fn revision(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    query_scalar("SELECT revision FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read revision")
}

async fn audit_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM audit_events")
        .fetch_one(db.pool())
        .await
        .expect("count audit events")
}

async fn seed_with_override(db: &AsyncDaemonDb, item_id: &str, verdict: TriageVerdict) {
    db.create_task_board_item(backlog_item(item_id))
        .await
        .expect("seed item");
    let expected_item_revision = revision(db, item_id).await;
    let expected_items_change_seq = seq(db).await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: item_id.into(),
        verdict,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");
}

#[tokio::test]
async fn set_lane_position_rejects_a_destination_conflicting_with_a_todo_override() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    let before_revision = revision(&db, "item-1").await;
    let before_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "item-1".into(),
            status: Some(TaskBoardStatus::Backlog),
            lane_position: 0,
            actor: "human-1".into(),
            expected_item_revision: before_revision,
            expected_items_change_seq: before_seq,
        })
        .await
        .expect_err("a destination conflicting with the override's lane is rejected");
    assert!(error.to_string().contains("triage override"));
    assert_eq!(revision(&db, "item-1").await, before_revision);
    assert_eq!(seq(&db).await, before_seq);
    assert_eq!(audit_count(&db).await, before_audit_count);
}

#[tokio::test]
async fn set_lane_position_rejects_a_destination_conflicting_with_an_undecided_override() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Undecided).await;
    let before_revision = revision(&db, "item-1").await;
    let before_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "item-1".into(),
            status: Some(TaskBoardStatus::Todo),
            lane_position: 0,
            actor: "human-1".into(),
            expected_item_revision: before_revision,
            expected_items_change_seq: before_seq,
        })
        .await
        .expect_err("a destination conflicting with the override's lane is rejected");
    assert!(error.to_string().contains("triage override"));
    assert_eq!(revision(&db, "item-1").await, before_revision);
    assert_eq!(seq(&db).await, before_seq);
    assert_eq!(audit_count(&db).await, before_audit_count);
}

#[tokio::test]
async fn set_lane_position_allows_a_same_lane_reorder_while_overridden() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    let before_revision = revision(&db, "item-1").await;
    let before_seq = seq(&db).await;

    let result = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "item-1".into(),
            status: Some(TaskBoardStatus::Todo),
            lane_position: 0,
            actor: "human-1".into(),
            expected_item_revision: before_revision,
            expected_items_change_seq: before_seq,
        })
        .await
        .expect("a same-lane reorder is allowed while overridden");
    assert_eq!(result.item.status, TaskBoardStatus::Todo);
    assert_eq!(result.item.lane_position, Some(0));
}
