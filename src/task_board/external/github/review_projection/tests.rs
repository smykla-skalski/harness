use tempfile::tempdir;

use super::*;
use crate::task_board::types::{ExternalRefSyncState, PlanningState, TaskBoardItem};

fn review_sync_state(status: TaskBoardStatus, updated_at: &str) -> ExternalRefSyncState {
    ExternalRefSyncState {
        status: Some(status),
        updated_at: Some(updated_at.to_owned()),
        ..ExternalRefSyncState::default()
    }
}

#[test]
fn review_status_reconciliation_uses_the_last_sync_as_shared_truth() {
    assert_eq!(
        reconciled_review_status(
            TaskBoardStatus::InProgress,
            Some(TaskBoardStatus::Todo),
            TaskBoardStatus::Todo,
        ),
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        reconciled_review_status(
            TaskBoardStatus::Todo,
            Some(TaskBoardStatus::Todo),
            TaskBoardStatus::Done,
        ),
        TaskBoardStatus::Done
    );
    assert_eq!(
        reconciled_review_status(
            TaskBoardStatus::InProgress,
            Some(TaskBoardStatus::Todo),
            TaskBoardStatus::Done,
        ),
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        reconciled_review_status(
            TaskBoardStatus::Done,
            Some(TaskBoardStatus::Done),
            TaskBoardStatus::Todo,
        ),
        TaskBoardStatus::Todo
    );
}

#[test]
fn review_status_reconciliation_canonicalizes_legacy_shared_truth() {
    for (current, last_synced) in [
        (TaskBoardStatus::Todo, TaskBoardStatus::New),
        (TaskBoardStatus::AgenticReview, TaskBoardStatus::PlanReview),
        (TaskBoardStatus::HumanRequired, TaskBoardStatus::NeedsYou),
        (TaskBoardStatus::Failed, TaskBoardStatus::Blocked),
    ] {
        assert_eq!(
            reconciled_review_status(current, Some(last_synced), TaskBoardStatus::Done),
            TaskBoardStatus::Done
        );
    }
}

#[test]
fn shared_review_snapshot_completes_imported_review_request() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Old title".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    item.project_id = Some("Example/Repo".into());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.planning = PlanningState {
        summary: Some("Review the linked pull request.".into()),
        approved_by: None,
        approved_at: None,
    };
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: Some(review_sync_state(
            TaskBoardStatus::Todo,
            "2026-07-11T10:00:00Z",
        )),
    }];
    board.create("Old title", "Body", item).expect("create");

    let changed = reconcile_pull_request_snapshots(
        &board,
        &[GitHubPullRequestSnapshot {
            repository: "example/repo".into(),
            number: 42,
            is_open: Some(true),
            viewer_review_requested: Some(false),
            updated_at: "2026-07-11T11:00:00Z".into(),
        }],
    )
    .expect("reconcile");

    let updated = board.get("github-example-repo-42").expect("updated item");
    assert!(changed);
    assert_eq!(updated.title, "Old title");
    assert_eq!(updated.status, TaskBoardStatus::Done);
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Done)
    );
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.updated_at.as_deref()),
        Some("2026-07-11T11:00:00Z")
    );
}

#[test]
fn shared_review_snapshot_does_not_touch_manual_task() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "manual-review".into(),
        "Manual task".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: None,
    }];
    board.create("Manual task", "Body", item).expect("create");

    let changed = reconcile_pull_request_snapshots(
        &board,
        &[GitHubPullRequestSnapshot {
            repository: "example/repo".into(),
            number: 42,
            is_open: Some(false),
            viewer_review_requested: Some(false),
            updated_at: "2026-07-11T11:00:00Z".into(),
        }],
    )
    .expect("reconcile");

    assert!(!changed);
    assert_eq!(
        board.get("manual-review").expect("manual item").title,
        "Manual task"
    );
}

#[test]
fn active_review_request_preserves_local_workflow_progress() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Review title".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::AgenticReview;
    item.project_id = Some("example/repo".into());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: Some(review_sync_state(
            TaskBoardStatus::Todo,
            "2026-07-11T10:00:00Z",
        )),
    }];
    board.create("Review title", "Body", item).expect("create");

    let changed = reconcile_pull_request_snapshots(
        &board,
        &[GitHubPullRequestSnapshot {
            repository: "example/repo".into(),
            number: 42,
            is_open: Some(true),
            viewer_review_requested: Some(true),
            updated_at: "2026-07-11T11:00:00Z".into(),
        }],
    )
    .expect("reconcile");

    assert!(changed);
    assert_eq!(
        board
            .get("github-example-repo-42")
            .expect("review item")
            .status,
        TaskBoardStatus::AgenticReview
    );
}

#[test]
fn unknown_viewer_does_not_complete_review_request() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Review title".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    item.project_id = Some("example/repo".into());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: None,
    }];
    board.create("Review title", "Body", item).expect("create");

    let changed = reconcile_pull_request_snapshots(
        &board,
        &[GitHubPullRequestSnapshot {
            repository: "example/repo".into(),
            number: 42,
            is_open: Some(true),
            viewer_review_requested: None,
            updated_at: "2026-07-11T11:00:00Z".into(),
        }],
    )
    .expect("reconcile");

    assert!(!changed);
    assert_eq!(
        board
            .get("github-example-repo-42")
            .expect("review item")
            .status,
        TaskBoardStatus::Todo
    );
}

#[test]
fn completed_remote_review_does_not_interrupt_active_execution() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Review title".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.project_id = Some("example/repo".into());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: Some(review_sync_state(
            TaskBoardStatus::Todo,
            "2026-07-11T10:00:00Z",
        )),
    }];
    board.create("Review title", "Body", item).expect("create");

    let changed = reconcile_pull_request_snapshots(
        &board,
        &[GitHubPullRequestSnapshot {
            repository: "example/repo".into(),
            number: 42,
            is_open: Some(false),
            viewer_review_requested: Some(false),
            updated_at: "2026-07-11T11:00:00Z".into(),
        }],
    )
    .expect("reconcile");

    assert!(changed);
    assert_eq!(
        board
            .get("github-example-repo-42")
            .expect("review item")
            .status,
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        board
            .get("github-example-repo-42")
            .expect("review item")
            .external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Done)
    );
}

#[test]
fn candidate_projection_reloads_refs_edited_after_listing() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Review title".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    item.project_id = Some("example/repo".into());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: Some(review_sync_state(
            TaskBoardStatus::Todo,
            "2026-07-11T10:00:00Z",
        )),
    }];
    board.create("Review title", "Body", item).expect("create");
    let candidate_id = board.list(None).expect("list")[0].id.clone();
    let mut latest_refs = board.get(&candidate_id).expect("item").external_refs;
    latest_refs.push(ExternalRef {
        provider: ExternalRefProvider::Todoist,
        external_id: "user-added".into(),
        url: Some("https://todoist.com/showTask?id=user-added".into()),
        sync_state: None,
    });
    board
        .update(
            &candidate_id,
            TaskBoardItemPatch {
                external_refs: Some(latest_refs),
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("user ref edit");
    let snapshot = GitHubPullRequestSnapshot {
        repository: "example/repo".into(),
        number: 42,
        is_open: Some(false),
        viewer_review_requested: Some(false),
        updated_at: "2026-07-11T11:00:00Z".into(),
    };
    let snapshots = BTreeMap::from([(snapshot_key("example/repo", 42), &snapshot)]);

    assert!(reconcile_candidate(&board, &candidate_id, &snapshots).expect("reconcile"));
    let updated = board.get(&candidate_id).expect("updated");
    assert_eq!(updated.status, TaskBoardStatus::Done);
    assert_eq!(updated.external_refs.len(), 2);
    assert_eq!(updated.external_refs[1].external_id, "user-added");
}

#[test]
fn aggregate_omission_does_not_complete_imported_review_request() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Review title".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#42".into(),
        url: Some("https://github.com/example/repo/pull/42".into()),
        sync_state: None,
    }];
    board.create("Review title", "Body", item).expect("create");

    assert!(!reconcile_pull_request_snapshots(&board, &[]).expect("reconcile"));
    assert_eq!(
        board
            .get("github-example-repo-42")
            .expect("review item")
            .status,
        TaskBoardStatus::Todo
    );
}

#[test]
fn active_imported_reviews_are_discovered_for_exact_resolution() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut active = TaskBoardItem::new(
        "github-example-repo-42".into(),
        "Active review".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    active.status = TaskBoardStatus::InProgress;
    active.imported_from_provider = Some(ExternalRefProvider::GitHub);
    active.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "Example/Repo#42".into(),
        url: Some("https://github.com/Example/Repo/pull/42".into()),
        sync_state: Some(review_sync_state(
            TaskBoardStatus::Todo,
            "2026-07-11T10:00:00Z",
        )),
    }];
    board
        .create("Active review", "Body", active)
        .expect("create active");

    let mut completed = TaskBoardItem::new(
        "github-example-repo-43".into(),
        "Completed review".into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    completed.status = TaskBoardStatus::Done;
    completed.imported_from_provider = Some(ExternalRefProvider::GitHub);
    completed.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/repo#43".into(),
        url: Some("https://github.com/example/repo/pull/43".into()),
        sync_state: Some(review_sync_state(
            TaskBoardStatus::Done,
            "2026-07-11T10:00:00Z",
        )),
    }];
    board
        .create("Completed review", "Body", completed)
        .expect("create completed");

    assert_eq!(
        imported_review_pull_request_references(&board).expect("references"),
        vec![("example/repo".to_string(), 42)]
    );
}
