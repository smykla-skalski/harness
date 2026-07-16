use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, TaskBoardConflictState, TaskBoardItem,
    TaskBoardSyncConflict,
};

#[tokio::test]
async fn stale_conflict_snapshot_cannot_replace_newer_item_revision() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = TaskBoardItem::new(
        "task-revision-fence".into(),
        "Original title".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    );
    db.create_task_board_item(item).await.expect("create item");
    let conflict = conflict_at_revision(1);
    db.update_task_board_item("task-revision-fence", |item| {
        item.title = "Concurrent title".into();
        Ok(true)
    })
    .await
    .expect("concurrent edit");

    let error = db
        .replace_open_task_board_sync_conflicts(
            "task-revision-fence",
            ExternalProvider::GitHub,
            "acme/widgets#17",
            1,
            &[conflict],
        )
        .await
        .expect_err("stale conflict snapshot must be rejected");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("open conflicts")
            .is_empty()
    );
}

#[tokio::test]
async fn conflict_payload_revision_must_match_replacement_revision() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = TaskBoardItem::new(
        "task-revision-fence".into(),
        "Original title".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    );
    db.create_task_board_item(item).await.expect("create item");
    let conflict = conflict_at_revision(0);

    let error = db
        .replace_open_task_board_sync_conflicts(
            "task-revision-fence",
            ExternalProvider::GitHub,
            "acme/widgets#17",
            1,
            &[conflict],
        )
        .await
        .expect_err("mismatched conflict revision must be rejected");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("open conflicts")
            .is_empty()
    );
}

fn conflict_at_revision(item_revision: i64) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: "conflict-revision-fence".into(),
        item_id: "task-revision-fence".into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: "acme/widgets#17".into(),
        field: "title".into(),
        base_value: serde_json::json!("Base title"),
        local_value: serde_json::json!("Original title"),
        remote_value: serde_json::json!("Remote title"),
        item_revision,
        provider_revision: Some("provider-revision-2".into()),
        state: TaskBoardConflictState::Open,
    }
}
