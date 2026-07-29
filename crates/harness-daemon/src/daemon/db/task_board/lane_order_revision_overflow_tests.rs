use sqlx::{query, query_scalar};

use super::*;

#[tokio::test]
async fn position_change_rejects_item_revision_overflow_without_writes() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    set_revision(&db, "a", i64::MAX).await;
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: None,
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: i64::MAX,
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect_err("revision overflow rejects position change");

    assert!(error.to_string().contains("item revision is out of range"));
    assert_unchanged(&db, &before, &["a"], before_audit_count).await;
}

#[tokio::test]
async fn anchor_shift_rejects_revision_overflow_and_rolls_back_every_write() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    db.create_task_board_item(item("b", "2026-07-22T10:01:00Z"))
        .await
        .expect("create b");
    anchor(&db, "a", 0).await;
    set_revision(&db, "a", i64::MAX).await;
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "b".into(),
            status: None,
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: revision(&before, "b"),
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect_err("shift revision overflow rejects position change");

    assert!(error.to_string().contains("item revision is out of range"));
    assert_unchanged(&db, &before, &["a", "b"], before_audit_count).await;
}

async fn set_revision(db: &AsyncDaemonDb, item_id: &str, revision: i64) {
    query("UPDATE task_board_items SET revision = ?1 WHERE item_id = ?2")
        .bind(revision)
        .bind(item_id)
        .execute(db.pool())
        .await
        .expect("set item revision");
}

async fn assert_unchanged(
    db: &AsyncDaemonDb,
    before: &super::super::lane_order::TaskBoardItemsSnapshot,
    expected_order: &[&str],
    before_audit_count: i64,
) {
    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after.items_change_seq, before.items_change_seq);
    assert_positions(&after, expected_order);
    for item in &before.items {
        assert_eq!(revision(&after, &item.item.id), item.item_revision);
        assert_eq!(item_from(&after, &item.item.id), &item.item);
    }
    assert_eq!(audit_count(db).await, before_audit_count);
}

async fn audit_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM audit_events")
        .fetch_one(db.pool())
        .await
        .expect("count audit events")
}
