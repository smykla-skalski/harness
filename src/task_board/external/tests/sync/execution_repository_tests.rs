use tempfile::tempdir;

use super::super::support::{FakeSyncClient, github_review_request_item};
use crate::task_board::{
    ExternalProvider, ExternalSyncAction, ExternalSyncClient, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncOptions, ExternalTask, ExternalTaskRef, TaskBoardStatus,
    TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn sync_external_tasks_backfills_execution_repository_for_existing_github_items() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = github_review_request_item(
        "github-owner-repo-18",
        "owner/repo#18",
        TaskBoardStatus::Backlog,
    );
    item.execution_repository = None;
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create existing GitHub item");
    let remote = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#18")
            .with_url("https://example.test/pull/owner/repo#18"),
        title: "Review requested".to_owned(),
        body: "Please review the pull request.".to_owned(),
        status: TaskBoardStatus::Backlog,
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_owned()),
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![remote],
    ))];
    let options = ExternalSyncOptions {
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
        status: None,
    };

    let operations = sync_external_tasks(&board, options, &clients)
        .await
        .expect("backfill execution repository");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert!(operations[0].applied);
    assert_eq!(
        board
            .get("github-owner-repo-18")
            .expect("load backfilled item")
            .execution_repository
            .as_deref(),
        Some("owner/repo")
    );
    assert!(
        sync_external_tasks(&board, options, &clients)
            .await
            .expect("repeat sync")
            .is_empty()
    );
}
