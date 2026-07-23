use tempfile::tempdir;

use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{ExternalRefProvider, ProviderExclusionAuditContext};

#[tokio::test]
async fn todo_filtered_pull_restores_an_open_provider_exclusion_tombstone() {
    let temp = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    let mut item = linked_item(
        "hidden-backlog",
        "Hidden item",
        "Body",
        TaskBoardStatus::Backlog,
    );
    item.tags = vec!["duplicate".into()];
    item.external_refs[0]
        .sync_state
        .as_mut()
        .expect("sync state")
        .labels = vec!["duplicate".into()];
    let created = db
        .create_task_board_item(item)
        .await
        .expect("create local task");
    db.hide_task_board_item_for_provider_exclusion(
        "hidden-backlog",
        created.item_revision,
        TaskBoardItemPatch::default(),
        &ProviderExclusionAuditContext {
            provider: ExternalRefProvider::Todoist,
            incoming_external_ref: "remote-1".into(),
            stored_external_ref: "remote-1".into(),
            matched_label: "duplicate".into(),
        },
        None,
    )
    .await
    .expect("hide call")
    .expect("item is hidden");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        Vec::new(),
        vec![remote_task(
            "remote-1",
            "Hidden item",
            "Body",
            TaskBoardStatus::Backlog,
        )],
    ))];

    let operations = sync_external_tasks(
        &db,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: Some(TaskBoardStatus::Todo),
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert!(
        !db.task_board_item_snapshot("hidden-backlog")
            .await
            .expect("load restored item")
            .item
            .is_deleted()
    );
    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
}
