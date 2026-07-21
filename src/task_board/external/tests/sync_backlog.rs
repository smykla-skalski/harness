use tempfile::tempdir;

use super::support::{FakeSyncClient, external_task, github_review_request_item};
use crate::task_board::{
    ExternalProvider, ExternalSyncAction, ExternalSyncClient, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncOptions, ExternalTask, ExternalTaskRef, TaskBoardStatus,
    TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn todo_filtered_sync_does_not_import_new_backlog_tasks() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![external_task("remote-backlog", "Unprocessed task")],
    ))];

    let operations = sync_external_tasks(
        &board,
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

    assert!(operations.is_empty());
    assert!(board.list(None).expect("list board").is_empty());
}

#[tokio::test]
async fn todo_filtered_bidirectional_sync_preserves_legacy_todo_without_stale_churn() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = github_review_request_item(
        "github-owner-repo-74",
        "owner/repo#74",
        TaskBoardStatus::Todo,
    );
    item.external_refs[0]
        .sync_state
        .as_mut()
        .expect("sync state")
        .status = Some(TaskBoardStatus::Todo);
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create legacy todo review");
    let remote = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#74")
            .with_url("https://example.test/pull/owner/repo#74"),
        title: "Review requested".to_owned(),
        body: "Please review the pull request.".to_owned(),
        status: TaskBoardStatus::Backlog,
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T04:00:00Z".to_owned()),
        ..ExternalTask::default()
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, vec![remote])
            .with_authoritative_review_inbox(),
    )];
    let options = ExternalSyncOptions {
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Both,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
        status: Some(TaskBoardStatus::Todo),
    };

    let first = sync_external_tasks(&board, options, &clients)
        .await
        .expect("sync legacy todo");
    let updated = board.get("github-owner-repo-74").expect("load legacy todo");

    assert_eq!(first.len(), 1);
    assert_eq!(first[0].action, ExternalSyncAction::Pull);
    assert_eq!(updated.status, TaskBoardStatus::Todo);
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Backlog)
    );

    let repeated = sync_external_tasks(&board, options, &clients)
        .await
        .expect("repeat legacy todo sync");
    assert!(repeated.is_empty());
}

#[tokio::test]
async fn todo_filtered_bidirectional_sync_preserves_open_workflow_lane_without_churn() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let item = github_review_request_item(
        "github-owner-repo-75",
        "owner/repo#75",
        TaskBoardStatus::InProgress,
    );
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create in-progress review");
    let remote = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#75")
            .with_url("https://example.test/pull/owner/repo#75"),
        title: "Review requested".to_owned(),
        body: "Please review the pull request.".to_owned(),
        status: TaskBoardStatus::Backlog,
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_owned()),
        ..ExternalTask::default()
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, vec![remote])
            .with_authoritative_review_inbox(),
    )];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: Some(TaskBoardStatus::Todo),
        },
        &clients,
    )
    .await
    .expect("sync in-progress review");

    assert!(operations.is_empty());
    assert_eq!(
        board
            .get("github-owner-repo-75")
            .expect("load in-progress review")
            .status,
        TaskBoardStatus::InProgress
    );
}

#[tokio::test]
async fn todo_filtered_sync_reconciles_terminal_truth_for_every_existing_item() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    for (id, external_id, status) in [
        (
            "github-owner-repo-76",
            "owner/repo#76",
            TaskBoardStatus::Backlog,
        ),
        (
            "github-owner-repo-77",
            "owner/repo#77",
            TaskBoardStatus::InProgress,
        ),
    ] {
        let item = github_review_request_item(id, external_id, status);
        board
            .create("Review requested", "Please review the pull request.", item)
            .expect("create existing review");
    }
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![
            terminal_review_task("owner/repo#76"),
            terminal_review_task("owner/repo#77"),
        ],
    ))];

    let operations = sync_external_tasks(
        &board,
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
    .expect("sync terminal reviews");

    assert_eq!(operations.len(), 2);
    let backlog = board
        .get("github-owner-repo-76")
        .expect("load backlog review");
    let in_progress = board
        .get("github-owner-repo-77")
        .expect("load in-progress review");
    assert_eq!(backlog.status, TaskBoardStatus::Done);
    assert_eq!(in_progress.status, TaskBoardStatus::InProgress);
    for item in [&backlog, &in_progress] {
        assert_eq!(
            item.external_refs[0]
                .sync_state
                .as_ref()
                .and_then(|state| state.status),
            Some(TaskBoardStatus::Done)
        );
    }
}

fn terminal_review_task(external_id: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, external_id)
            .with_url(format!("https://example.test/pull/{external_id}")),
        title: "Review requested".to_owned(),
        body: "Please review the pull request.".to_owned(),
        status: TaskBoardStatus::Done,
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T04:00:00Z".to_owned()),
        ..ExternalTask::default()
    }
}
