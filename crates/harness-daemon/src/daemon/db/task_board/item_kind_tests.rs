use sqlx::query;
use sqlx::query_scalar;
use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::TaskBoardItem;
use crate::task_board::types::TaskBoardItemKind;

#[tokio::test]
async fn a_future_kind_deserializes_safely_and_survives_an_unrelated_update() {
    let (_dir, db) = connect().await;
    db.create_task_board_item(item("task-future-kind"))
        .await
        .expect("create item");
    query("UPDATE task_board_items SET kind = 'epic' WHERE item_id = ?1")
        .bind("task-future-kind")
        .execute(db.pool())
        .await
        .expect("inject a future kind this binary does not recognize");

    let loaded = db
        .task_board_item("task-future-kind")
        .await
        .expect("a future kind must not fail to load");
    assert_eq!(loaded.kind, TaskBoardItemKind::Unknown("epic".into()));

    db.update_task_board_item("task-future-kind", |current| {
        current.title = "Renamed".to_string();
        Ok(true)
    })
    .await
    .expect("update item")
    .expect("mutation");

    let stored_kind: String = query_scalar("SELECT kind FROM task_board_items WHERE item_id = ?1")
        .bind("task-future-kind")
        .fetch_one(db.pool())
        .await
        .expect("read stored kind");
    assert_eq!(
        stored_kind, "epic",
        "an update to an unrelated field must not downgrade a future kind to the literal string 'unknown'"
    );
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
        "Future kind".to_owned(),
        "Body".to_owned(),
        "2026-07-21T10:00:00Z".to_owned(),
    )
}
