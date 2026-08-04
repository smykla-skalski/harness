use tempfile::tempdir;

use harness::daemon::db::{AsyncDaemonDb, AsyncDaemonDbConnect};
use harness::daemon::db_handle::AsyncDaemonDbHandle;
use harness::task_board::external::{
    ExternalSyncClient, ExternalSyncOptions, TaskBoardSyncStore, sync_external_tasks,
};
use harness::task_board::{
    ExternalProvider, ExternalSyncAction, ExternalSyncConflictPolicy, ExternalSyncDirection,
    ExternalSyncField, TaskBoardStatus,
};
use harness_task_board_provider_sync::open_task_board_sync_conflicts;

use super::support::{UpdateFakeSyncClient, linked_item, remote_task};

#[tokio::test]
async fn pull_report_is_remote_authoritative_but_prefer_local_is_explicit() {
    let cases = [
        (
            ExternalSyncConflictPolicy::Report,
            "task-pull-report",
            "Remote title",
        ),
        (
            ExternalSyncConflictPolicy::PreferLocal,
            "task-pull-prefer-local",
            "Local title",
        ),
    ];

    for (policy, item_id, expected_title) in cases {
        let temp = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("database");
        let db = AsyncDaemonDbHandle(db);
        db.create_item(linked_item(
            item_id,
            "Local title",
            "Old body",
            TaskBoardStatus::Todo,
        ))
        .await
        .expect("create local task");
        let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
            ExternalProvider::GitHub,
            vec![ExternalSyncField::Title],
            vec![remote_task(
                "remote-1",
                "Remote title",
                "Old body",
                TaskBoardStatus::Inbox,
            )],
        ))];

        let operations = sync_external_tasks(
            &db,
            ExternalSyncOptions {
                provider: Some(ExternalProvider::GitHub),
                direction: ExternalSyncDirection::Pull,
                conflict_policy: policy,
                dry_run: false,
                status: None,
            },
            &clients,
        )
        .await
        .expect("pull external task");

        assert_eq!(
            db.item_snapshot(item_id)
                .await
                .expect("reconciled item")
                .item
                .title,
            expected_title
        );
        if policy == ExternalSyncConflictPolicy::Report {
            assert_eq!(operations.len(), 1);
            assert_eq!(operations[0].action, ExternalSyncAction::Pull);
            assert!(operations[0].applied);
            assert!(
                operations[0]
                    .changed_fields
                    .contains(&ExternalSyncField::Title)
            );
            assert!(
                open_task_board_sync_conflicts(&db)
                    .await
                    .expect("open conflicts")
                    .is_empty()
            );
        }
    }
}
