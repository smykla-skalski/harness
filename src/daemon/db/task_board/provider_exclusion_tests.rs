use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardTombstoneCause};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn pre_dispatch_item(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item.tags = vec!["duplicate".into()];
    item
}

#[tokio::test]
async fn hides_a_pre_dispatch_item_and_records_exactly_one_audit_event() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion("item-1")
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    assert!(mutation.item.is_deleted());
    assert_eq!(
        mutation.item.tombstone_cause,
        Some(TaskBoardTombstoneCause::ProviderExclusion)
    );

    let audit_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_hidden' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count audit events");
    assert_eq!(
        audit_count, 1,
        "hide must record exactly one typed audit event even without a lane anchor"
    );
}

#[tokio::test]
async fn refuses_to_hide_an_item_with_a_pending_dispatch_intent() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, created_at, updated_at
         ) VALUES ('intent-1', 'item-1', 'session-1', 'work-1', 'workflow-1', '{}',
                    'pending', 0,
                    '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed pending dispatch intent");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion("item-1")
        .await
        .expect("hide call succeeds");

    assert!(
        mutation.is_none(),
        "an item with a pending dispatch intent must never be silently hidden"
    );
}

#[tokio::test]
async fn refuses_to_hide_an_item_with_a_held_dispatch_intent() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, created_at, updated_at
         ) VALUES ('intent-1', 'item-1', 'session-1', 'work-1', 'workflow-1', '{}',
                    'held', 0,
                    '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed held dispatch intent");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion("item-1")
        .await
        .expect("hide call succeeds");

    assert!(
        mutation.is_none(),
        "an item held pending admission must never be silently hidden"
    );
}

#[tokio::test]
async fn hiding_a_parent_clears_its_children_parent_link() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("parent"))
        .await
        .expect("seed parent");
    let mut child = pre_dispatch_item("child");
    child.parent_item_id = Some("parent".into());
    db.create_task_board_item(child)
        .await
        .expect("seed child");

    db.hide_task_board_item_for_provider_exclusion("parent")
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    let child = db.task_board_item("child").await.expect("load child");
    assert_eq!(
        child.parent_item_id, None,
        "a hidden parent must not leave a live child pointing at it"
    );
}

#[tokio::test]
async fn refuses_to_hide_an_item_past_pre_dispatch_status() {
    let (_directory, db) = connect().await;
    let mut item = pre_dispatch_item("item-1");
    item.status = TaskBoardStatus::InProgress;
    db.create_task_board_item(item).await.expect("seed item");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion("item-1")
        .await
        .expect("hide call succeeds");

    assert!(
        mutation.is_none(),
        "an item past pre-dispatch (Backlog/Todo) must never be silently hidden"
    );
}
