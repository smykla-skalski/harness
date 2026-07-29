use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalSyncField, TaskBoardConflictState,
    TaskBoardItem, TaskBoardSyncConflict,
};

#[tokio::test]
async fn field_scoped_supersession_preserves_unsupported_conflicts_and_publishes_once() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    db.create_task_board_item(TaskBoardItem::new(
        "task-conflict-fields".into(),
        "Task".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let conflicts = [
        conflict("conflict-title", "title"),
        conflict("conflict-project", "project"),
        conflict("conflict-future", "future_field"),
    ];
    db.replace_open_task_board_sync_conflicts(
        "task-conflict-fields",
        ExternalProvider::GitHub,
        "example/repository#51",
        1,
        &conflicts,
    )
    .await
    .expect("record conflicts");
    let before = db
        .current_change_sequence()
        .await
        .expect("initial sequence");

    db.supersede_open_task_board_sync_conflicts(
        "task-conflict-fields",
        ExternalProvider::GitHub,
        "example/repository#51",
        1,
        &[ExternalSyncField::Title],
    )
    .await
    .expect("supersede selected conflicts");

    assert_eq!(
        db.current_change_sequence()
            .await
            .expect("changed sequence"),
        before + 1
    );
    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    let mut open_fields = open
        .iter()
        .map(|conflict| conflict.field.as_str())
        .collect::<Vec<_>>();
    open_fields.sort_unstable();
    assert_eq!(open_fields, vec!["future_field", "project"],);

    db.supersede_open_task_board_sync_conflicts(
        "task-conflict-fields",
        ExternalProvider::GitHub,
        "example/repository#51",
        1,
        &[ExternalSyncField::Title],
    )
    .await
    .expect("repeat selected supersession");
    assert_eq!(
        db.current_change_sequence().await.expect("stable sequence"),
        before + 1
    );
}

#[tokio::test]
async fn field_scoped_supersession_rejects_stale_item_revision_without_mutation() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    db.create_task_board_item(TaskBoardItem::new(
        "task-conflict-stale".into(),
        "Task".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    ))
    .await
    .expect("create item");
    db.replace_open_task_board_sync_conflicts(
        "task-conflict-stale",
        ExternalProvider::GitHub,
        "example/repository#52",
        1,
        &[conflict_for_item(
            "task-conflict-stale",
            "conflict-stale-title",
            "title",
        )],
    )
    .await
    .expect("record conflict");
    db.update_task_board_item("task-conflict-stale", |item| {
        item.title = "Concurrent title".into();
        Ok(true)
    })
    .await
    .expect("concurrent edit");
    let before = db
        .current_change_sequence()
        .await
        .expect("initial sequence");

    let error = db
        .supersede_open_task_board_sync_conflicts(
            "task-conflict-stale",
            ExternalProvider::GitHub,
            "example/repository#52",
            1,
            &[ExternalSyncField::Title],
        )
        .await
        .expect_err("stale revision must fail");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(
        db.current_change_sequence().await.expect("stable sequence"),
        before
    );
    assert_eq!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("open conflicts")
            .len(),
        1
    );
}

fn conflict(conflict_id: &str, field: &str) -> TaskBoardSyncConflict {
    conflict_for_item("task-conflict-fields", conflict_id, field)
}

fn conflict_for_item(item_id: &str, conflict_id: &str, field: &str) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: conflict_id.into(),
        item_id: item_id.into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: if item_id == "task-conflict-fields" {
            "example/repository#51".into()
        } else {
            "example/repository#52".into()
        },
        field: field.into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision: 1,
        provider_revision: Some("provider-revision-1".into()),
        state: TaskBoardConflictState::Open,
    }
}
