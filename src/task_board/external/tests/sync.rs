use tempfile::tempdir;

use super::support::{FakeSyncClient, external_task, github_review_request_item};
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalRefSyncState, ExternalSyncAction,
    ExternalSyncClient, ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncField,
    ExternalSyncOptions, ExternalTask, ExternalTaskRef, TaskBoardItem, TaskBoardStatus,
    TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn fake_client_pulls_tasks_without_network() {
    let client = FakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![external_task("remote-1", "Remote task")],
    );

    let tasks = client.pull_tasks().await.expect("fake pull should succeed");

    assert_eq!(client.provider(), ExternalProvider::Todoist);
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].title, "Remote task");
    assert_eq!(tasks[0].status, TaskBoardStatus::Backlog);
}

#[tokio::test]
async fn fake_client_pushes_task_without_network() {
    let mut item = TaskBoardItem::new(
        "task-1".to_owned(),
        "Local task".to_owned(),
        "Body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    item.status = TaskBoardStatus::InProgress;
    let client = FakeSyncClient::new(ExternalProvider::GitHub, Vec::new());

    let reference = client
        .push_task(&item)
        .await
        .expect("fake push should succeed");

    assert_eq!(reference.provider, ExternalProvider::GitHub);
    assert_eq!(reference.external_id, "task-1");
    assert_eq!(client.pushed_ids(), vec!["task-1"]);
}

#[tokio::test]
async fn sync_external_tasks_uses_injected_clients_without_network() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Local task".to_owned(),
        "Body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local.status = TaskBoardStatus::Todo;
    board
        .create("Local task", "Body", local)
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![external_task("remote-1", "Remote task")],
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 2);
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Pull
            && operation.board_item_id.as_deref() == Some("todoist-remote-1")
            && operation.applied
    }));
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Push
            && operation.board_item_id.as_deref() == Some("local-1")
            && operation.external_id.as_deref() == Some("local-1")
            && operation.applied
    }));
    let pulled = board.get("todoist-remote-1").expect("load pulled task");
    assert_eq!(pulled.title, "Remote task");
    let pushed = board.get("local-1").expect("load pushed task");
    assert!(pushed.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::Todoist && reference.external_id == "local-1"
    }));
}

#[tokio::test]
async fn sync_external_tasks_dry_run_does_not_write_board() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Local task".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    board
        .create("Local task", "", local)
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![external_task("remote-2", "Remote task")],
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: true,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 2);
    assert!(operations.iter().all(|operation| !operation.applied));
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Pull
            && operation.board_item_id.as_deref() == Some("todoist-remote-2")
            && operation.external_id.as_deref() == Some("remote-2")
            && operation.dry_run
    }));
    assert!(operations.iter().any(|operation| {
        operation.action == ExternalSyncAction::Push
            && operation.board_item_id.as_deref() == Some("local-1")
            && operation.dry_run
    }));
    assert!(board.get("todoist-remote-2").is_err());
    assert!(
        board
            .get("local-1")
            .expect("local task")
            .external_refs
            .is_empty()
    );
}

#[tokio::test]
async fn sync_external_tasks_reconciles_closed_existing_provider_ref() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Old title".to_owned(),
        "Old body".to_owned(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local.status = TaskBoardStatus::Todo;
    local.external_refs.push(
        ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1")
            .with_url("https://example.test/old")
            .into_core_ref(),
    );
    board
        .create("Old title", "Old body", local)
        .expect("create local task");
    let remote = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1")
            .with_url("https://example.test/new"),
        title: "New title".to_owned(),
        body: "New body".to_owned(),
        status: TaskBoardStatus::Done,
        project_id: Some("provider/project".to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_string()),
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![remote],
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
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
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert_eq!(operations[0].board_item_id.as_deref(), Some("local-1"));
    assert!(operations[0].applied);
    let updated = board.get("local-1").expect("load reconciled task");
    assert_eq!(updated.title, "New title");
    assert_eq!(updated.body, "New body");
    assert_eq!(updated.status, TaskBoardStatus::Done);
    assert_eq!(updated.project_id.as_deref(), Some("provider/project"));
    assert!(updated.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::Todoist
            && reference.external_id == "remote-1"
            && reference.url.as_deref() == Some("https://example.test/new")
    }));
}

#[tokio::test]
async fn sync_external_tasks_dry_run_reports_reconciliation_without_writing() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut local = TaskBoardItem::new(
        "local-1".to_owned(),
        "Old title".to_owned(),
        String::new(),
        "2026-05-14T00:00:00Z".to_owned(),
    );
    local
        .external_refs
        .push(ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1").into_core_ref());
    board
        .create("Old title", "", local)
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![external_task("remote-1", "New title")],
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
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
    assert_eq!(operations[0].board_item_id.as_deref(), Some("local-1"));
    assert!(operations[0].dry_run);
    assert!(!operations[0].applied);
    assert_eq!(board.get("local-1").expect("local task").title, "Old title");
}

#[tokio::test]
async fn todo_filtered_stale_review_sync_preserves_local_status() {
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
