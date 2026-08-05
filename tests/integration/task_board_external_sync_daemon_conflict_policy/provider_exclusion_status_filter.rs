use tempfile::tempdir;

use harness::daemon::db::{AsyncDaemonDb, AsyncDaemonDbConnect};
use harness::daemon::db_handle::AsyncDaemonDbHandle;
use harness::task_board::external::{
    ExternalSyncClient, ExternalSyncOptions, TaskBoardSyncStore, sync_external_tasks,
};
use harness::task_board::store::TaskBoardItemPatch;
use harness::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalSyncConflictPolicy, ExternalSyncDirection,
    ProviderExclusionAuditContext, TaskBoardStatus,
};

use super::support::{UpdateFakeSyncClient, linked_item, remote_task};

#[tokio::test]
async fn todo_status_filtered_pull_restores_an_open_provider_exclusion_tombstone() {
    let temp = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    let db = AsyncDaemonDbHandle(db);
    let mut item = linked_item(
        "hidden-inbox",
        "Hidden item",
        "Body",
        TaskBoardStatus::Inbox,
    );
    item.tags = vec!["duplicate".into()];
    item.external_refs[0]
        .sync_state
        .as_mut()
        .expect("sync state")
        .labels = vec!["duplicate".into()];
    db.create_item(item).await.expect("create local task");
    let created = db
        .item_snapshot("hidden-inbox")
        .await
        .expect("load created item");
    db.hide_for_provider_exclusion(
        "hidden-inbox",
        created.item_revision,
        TaskBoardItemPatch::default(),
        ProviderExclusionAuditContext {
            provider: ExternalRefProvider::GitHub,
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
        ExternalProvider::GitHub,
        Vec::new(),
        vec![remote_task(
            "remote-1",
            "Hidden item",
            "Body",
            TaskBoardStatus::Inbox,
        )],
    ))];

    let operations = sync_external_tasks(
        &db,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
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
        !db.item_snapshot("hidden-inbox")
            .await
            .expect("load restored item")
            .item
            .is_deleted()
    );
    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
}
