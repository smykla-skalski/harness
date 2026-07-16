use tempfile::tempdir;

use super::*;
use crate::daemon::db::AsyncDaemonDb;

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
        db.create_task_board_item(linked_item(
            item_id,
            "Local title",
            "Old body",
            TaskBoardStatus::Todo,
        ))
        .await
        .expect("create local task");
        let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
            ExternalProvider::Todoist,
            vec![ExternalSyncField::Title],
            vec![remote_task(
                "remote-1",
                "Remote title",
                "Old body",
                TaskBoardStatus::Backlog,
            )],
        ))];

        let operations = sync_external_tasks(
            &db,
            ExternalSyncOptions {
                provider: Some(ExternalProvider::Todoist),
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
            db.task_board_item(item_id)
                .await
                .expect("reconciled item")
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
                db.open_task_board_sync_conflicts()
                    .await
                    .expect("open conflicts")
                    .is_empty()
            );
        }
    }
}
