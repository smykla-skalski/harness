use tempfile::tempdir;

use super::support::{FakeSyncClient, github_external_task, github_external_task_with_status};
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalRefProvider, ExternalRefSyncState, ExternalSyncClient,
    ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncOptions, ExternalTaskRef,
    TaskBoardItem, TaskBoardStatus, TaskBoardStore, build_dispatch_plan, sync_external_tasks,
};

#[tokio::test]
async fn sync_external_tasks_imports_github_tasks_with_plan_pending_approval() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![github_external_task("7", "Remote issue", "owner/repo")],
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

    assert_eq!(operations.len(), 1);
    let item = board
        .get("github-7-7902699be42c8a8e46fbbb4501726517")
        .expect("load imported github task");
    assert_eq!(item.status, TaskBoardStatus::Backlog);
    assert_eq!(item.project_id, None);
    assert_eq!(item.execution_repository.as_deref(), Some("owner/repo"));
    assert!(item.planning.approved_by.is_none());
    assert!(item.planning.approved_at.is_none());
    assert!(
        item.planning
            .summary
            .as_deref()
            .is_some_and(|summary| summary.contains("Remote issue"))
    );
    assert!(item.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::GitHub && reference.external_id == "7"
    }));
    assert!(!build_dispatch_plan(&item).is_ready());
}

#[tokio::test]
async fn sync_external_tasks_imports_github_inbox_items_as_backlog_with_plan_pending_approval() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![github_external_task_with_status(
            "owner/repo#19",
            "Review requested",
            "owner/repo",
            TaskBoardStatus::Backlog,
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

    let item = board
        .get("github-owner-repo-19-983c1507241b6007ac5729cfcea78b64")
        .expect("load imported github inbox task");
    assert_eq!(item.status, TaskBoardStatus::Backlog);
    assert_eq!(item.project_id, None);
    assert_eq!(item.execution_repository.as_deref(), Some("owner/repo"));
    assert!(item.planning.summary.is_some());
    assert!(item.planning.approved_by.is_none());
    assert!(item.planning.approved_at.is_none());
    assert!(item.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::GitHub
            && reference.external_id == "owner/repo#19"
    }));
    assert!(!build_dispatch_plan(&item).is_ready());
}

#[tokio::test]
async fn sync_external_tasks_keeps_github_refs_with_colliding_sanitized_ids_distinct() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![
            github_external_task("owner/repo#42", "Slash ref", "owner/repo"),
            github_external_task("owner-repo#42", "Dash ref", "owner/repo"),
        ],
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
    .expect("sync colliding sanitized GitHub refs");

    let items = board.list(None).expect("list imported GitHub tasks");
    assert_eq!(items.len(), 2);
    assert!(
        items
            .iter()
            .any(|item| { item.id == "github-owner-repo-42-9d2b21ac4ca2efd7eac0587d3a0f2ff3" })
    );
    assert!(
        items
            .iter()
            .any(|item| { item.id == "github-owner-repo-42-3d5fc6ccd05298bb4eea8b1634c66af5" })
    );
}

#[tokio::test]
async fn sync_external_tasks_reconciles_legacy_github_refs_by_project_scope() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    let mut primary = TaskBoardItem::new(
        "legacy-owner-repo".to_owned(),
        "Old title".to_owned(),
        "Body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    primary.status = TaskBoardStatus::Todo;
    primary.project_id = Some("portfolio-primary".to_owned());
    primary.execution_repository = Some("owner/repo".to_owned());
    primary.external_refs = vec![legacy_github_ref("7", "portfolio-primary")];
    board
        .create("Old title", "Body", primary)
        .expect("create primary task");

    let mut secondary = TaskBoardItem::new(
        "legacy-other-repo".to_owned(),
        "Other title".to_owned(),
        "Body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    secondary.status = TaskBoardStatus::Todo;
    secondary.project_id = Some("portfolio-secondary".to_owned());
    secondary.execution_repository = Some("other/repo".to_owned());
    secondary.external_refs = vec![legacy_github_ref("7", "portfolio-secondary")];
    board
        .create("Other title", "Body", secondary)
        .expect("create secondary task");

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![github_external_task(
            "owner/repo#7",
            "Updated title",
            "owner/repo",
        )],
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

    assert_eq!(operations.len(), 1);
    assert_eq!(board.list(None).expect("list items").len(), 2);

    let updated = board
        .get("legacy-owner-repo")
        .expect("load reconciled legacy task");
    assert_eq!(updated.title, "Updated title");
    assert_eq!(updated.project_id.as_deref(), Some("portfolio-primary"));
    assert_eq!(updated.execution_repository.as_deref(), Some("owner/repo"));
    assert!(updated.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::GitHub && reference.external_id == "owner/repo#7"
    }));

    let untouched = board
        .get("legacy-other-repo")
        .expect("load other repo task");
    assert_eq!(untouched.title, "Other title");
    assert_eq!(untouched.project_id.as_deref(), Some("portfolio-secondary"));
    assert_eq!(
        untouched.execution_repository.as_deref(),
        Some("other/repo")
    );
    assert!(untouched.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::GitHub && reference.external_id == "7"
    }));
}

fn legacy_github_ref(external_id: &str, stale_project_id: &str) -> ExternalRef {
    let mut reference = ExternalTaskRef::new(ExternalProvider::GitHub, external_id).into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        project_id: Some(stale_project_id.to_owned()),
        ..ExternalRefSyncState::default()
    });
    reference
}
