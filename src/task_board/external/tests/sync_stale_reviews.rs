//! Sync coverage for stale GitHub review-request reconciliation.
//!
//! Split out of `sync.rs` to keep both files under the repo's Rust source
//! length limit.

use tempfile::tempdir;

use super::support::FakeSyncClient;
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalRefSyncState, ExternalSyncClient,
    ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncField, ExternalSyncOptions,
    ExternalTaskRef, TaskBoardItem, TaskBoardStatus, TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn todo_status_filtered_stale_review_sync_preserves_local_status() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let item = super::support::github_review_request_item(
        "github-owner-repo-71",
        "owner/repo#71",
        TaskBoardStatus::AgenticReview,
    );
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create review request task");

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, Vec::new()).with_authoritative_review_inbox(),
    )];

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
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(
        operations[0].changed_fields,
        vec![ExternalSyncField::Status]
    );
    assert!(operations[0].applied);

    let updated = board
        .get("github-owner-repo-71")
        .expect("load resolved review request");
    assert_eq!(updated.status, TaskBoardStatus::AgenticReview);
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Done)
    );

    let repeated = sync_external_tasks(
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
    .expect("repeat sync external tasks");
    assert!(repeated.is_empty(), "recorded remote truth must not churn");
}

#[tokio::test]
async fn sync_external_tasks_dry_run_reports_stale_todo_github_review_requests_without_writing() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let item = super::support::github_review_request_item(
        "github-owner-repo-72",
        "owner/repo#72",
        TaskBoardStatus::Todo,
    );
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create review request task");

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, Vec::new()).with_authoritative_review_inbox(),
    )];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: true,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(
        operations[0].changed_fields,
        vec![ExternalSyncField::Status]
    );
    assert!(!operations[0].applied);

    let unchanged = board
        .get("github-owner-repo-72")
        .expect("load unchanged review request");
    assert_eq!(unchanged.status, TaskBoardStatus::Todo);
}

#[tokio::test]
async fn sync_external_tasks_resolves_stale_todo_github_review_requests() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let item = super::support::github_review_request_item(
        "github-owner-repo-73",
        "owner/repo#73",
        TaskBoardStatus::Todo,
    );
    board
        .create("Review requested", "Please review the pull request.", item)
        .expect("create todo review request task");

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, Vec::new()).with_authoritative_review_inbox(),
    )];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    let resolved = board
        .get("github-owner-repo-73")
        .expect("load resolved review request");
    assert_eq!(resolved.status, TaskBoardStatus::Done);
}

#[tokio::test]
async fn sync_external_tasks_marks_imported_from_provider_on_new_github_items() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![super::support::github_external_task(
            "owner/repo#21",
            "Imported issue",
            "owner/repo",
        )],
    ))];

    sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    let imported = board
        .get("github-owner-repo-21-c8d898f018309d954acd32bcfc9a755e")
        .expect("load imported github task");
    assert_eq!(
        imported.imported_from_provider,
        Some(ExternalRefProvider::GitHub)
    );
    assert_eq!(imported.execution_repository.as_deref(), Some("owner/repo"));
}

#[tokio::test]
async fn sync_external_tasks_skips_stale_review_check_when_item_was_not_imported_from_github() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "manual-review-1".to_owned(),
        "Review requested".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    item.status = TaskBoardStatus::AgenticReview;
    item.project_id = Some("owner/repo".to_owned());
    let mut reference = ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#88")
        .with_url("https://example.test/pull/88".to_owned())
        .into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Review requested".to_owned()),
        body: Some(String::new()),
        status: Some(TaskBoardStatus::HumanRequired),
        project_id: Some("owner/repo".to_owned()),
        updated_at: Some("2026-05-14T00:00:00Z".to_owned()),
        synced_at: Some("2026-05-14T00:00:00Z".to_owned()),
        labels: Vec::new(),
    });
    item.external_refs = vec![reference];
    board
        .create("Review requested", "", item)
        .expect("create manual review task");

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        Vec::new(),
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert!(operations.is_empty());
    let unchanged = board
        .get("manual-review-1")
        .expect("load manual review task");
    assert_eq!(unchanged.status, TaskBoardStatus::AgenticReview);
}
