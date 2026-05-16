use tempfile::tempdir;

use super::support::FakeSyncClient;
use crate::task_board::{
    ExternalProvider, ExternalSyncAction, ExternalSyncClient, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncOptions, ExternalTaskRef, TaskBoardItem, TaskBoardStatus,
    TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn sync_external_tasks_closes_remote_tasks_for_local_tombstones_when_provider_allows_delete()
{
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Local task".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local.status = TaskBoardStatus::Todo;
    local.external_refs =
        vec![ExternalTaskRef::new(ExternalProvider::Todoist, "remote-9").into_core_ref()];
    board
        .create("Local task", "", local)
        .expect("create local task");
    board.delete("local-1").expect("tombstone local task");

    let client = FakeSyncClient::new(ExternalProvider::Todoist, Vec::new()).with_delete();
    let deleted = client.deleted_handle();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Delete
            && operation.board_item_id.as_deref() == Some("local-1")
            && operation.applied
    }));
    let deleted_ids = deleted.lock().expect("deleted handle").clone();
    assert_eq!(deleted_ids, vec!["remote-9".to_string()]);
}

#[tokio::test]
async fn sync_external_tasks_skips_remote_delete_when_provider_default_disallows_it() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-2".to_owned(),
        "Local task".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local.external_refs =
        vec![ExternalTaskRef::new(ExternalProvider::Todoist, "remote-12").into_core_ref()];
    board
        .create("Local task", "", local)
        .expect("create local task");
    board.delete("local-2").expect("tombstone local task");

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::Todoist,
        Vec::new(),
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert!(
        operations
            .iter()
            .all(|operation| operation.action != ExternalSyncAction::Delete)
    );
}

#[tokio::test]
async fn sync_external_tasks_records_remote_delete_dry_run_without_calling_provider() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-3".to_owned(),
        "Local task".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local.external_refs =
        vec![ExternalTaskRef::new(ExternalProvider::Todoist, "remote-13").into_core_ref()];
    board
        .create("Local task", "", local)
        .expect("create local task");
    board.delete("local-3").expect("tombstone local task");

    let client = FakeSyncClient::new(ExternalProvider::Todoist, Vec::new()).with_delete();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: true,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Delete && operation.dry_run && !operation.applied
    }));
}
