use sqlx::query;
use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::TaskBoardItem;
use crate::task_board::types::MAX_TASK_BOARD_ESTIMATE;

#[tokio::test]
async fn estimates_round_trip_at_both_storage_boundaries_and_clear() {
    let (_dir, db) = connect().await;
    let mut item = item("task-estimate-round-trip");
    item.estimated_tokens = Some(1);
    item.estimated_cost_microusd = Some(MAX_TASK_BOARD_ESTIMATE);

    let created = db.create_task_board_item(item).await.expect("create item");
    assert_eq!(created.item_revision, 1);
    assert_eq!(created.item.estimated_tokens, Some(1));
    assert_eq!(
        created.item.estimated_cost_microusd,
        Some(MAX_TASK_BOARD_ESTIMATE)
    );

    let updated = db
        .update_task_board_item("task-estimate-round-trip", |current| {
            current.estimated_tokens = None;
            current.estimated_cost_microusd = Some(1);
            Ok(true)
        })
        .await
        .expect("update item")
        .expect("mutation");
    assert_eq!(updated.item_revision, 2);
    assert_eq!(updated.item.estimated_tokens, None);
    assert_eq!(updated.item.estimated_cost_microusd, Some(1));
}

#[tokio::test]
async fn invalid_estimate_update_leaves_item_and_revision_unchanged() {
    let (_dir, db) = connect().await;
    db.create_task_board_item(item("task-estimate-invalid"))
        .await
        .expect("create item");

    let error = db
        .update_task_board_item("task-estimate-invalid", |current| {
            current.estimated_tokens = Some(0);
            Ok(true)
        })
        .await
        .expect_err("zero estimate must fail");
    assert_eq!(error.code(), "WORKFLOW_IO");

    let snapshot = db
        .task_board_item_snapshot("task-estimate-invalid")
        .await
        .expect("unchanged snapshot");
    assert_eq!(snapshot.item_revision, 1);
    assert_eq!(snapshot.item.estimated_tokens, None);
}

#[tokio::test]
async fn corrupt_negative_estimate_fails_closed_during_mapping() {
    let (_dir, db) = connect().await;
    db.create_task_board_item(item("task-estimate-corrupt"))
        .await
        .expect("create item");
    let mut connection = db.pool().acquire().await.expect("acquire connection");
    query("PRAGMA ignore_check_constraints = ON")
        .execute(&mut *connection)
        .await
        .expect("disable checks for corruption fixture");
    query("UPDATE task_board_items SET estimated_tokens = -1 WHERE item_id = ?1")
        .bind("task-estimate-corrupt")
        .execute(&mut *connection)
        .await
        .expect("inject corrupt estimate");
    drop(connection);

    let error = db
        .task_board_item("task-estimate-corrupt")
        .await
        .expect_err("negative estimate must fail mapping");
    assert_eq!(error.code(), "WORKFLOW_IO");
}

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    (dir, db)
}

fn item(id: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        id.to_owned(),
        "Bounded estimate".to_owned(),
        "Body".to_owned(),
        "2026-07-17T10:00:00Z".to_owned(),
    )
}
