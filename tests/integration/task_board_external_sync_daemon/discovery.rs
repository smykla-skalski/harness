//! Pull-request discovery coverage: dependency and review intents must survive
//! the real sync engine as distinct or combined tickets, each recorded once
//! with its identity, and an omitted open review request must only close when
//! the pulling client reports a complete, authoritative inbox.

use tempfile::tempdir;

use std::collections::BTreeSet;

use harness::daemon::db::{AsyncDaemonDb, AsyncDaemonDbConnect};
use harness::task_board::external::{
    ExternalSyncClient, ExternalSyncOptions, TaskBoardSyncStore, sync_external_tasks,
};
use harness::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalSyncAction, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncOperation, ExternalTask, ExternalTaskRef, TaskBoardItem,
    TaskBoardStatus, TaskBoardWorkflowKind,
};

use super::support::{FakeSyncClient, github_review_request_item};

const REPOSITORY: &str = "acme/widgets";

/// The distinct board item ids a pull created or reconciled, read off the
/// returned operations because the imported id carries a content hash.
fn imported_item_ids(operations: &[ExternalSyncOperation]) -> Vec<String> {
    operations
        .iter()
        .filter(|operation| operation.action == ExternalSyncAction::Pull && operation.applied)
        .filter_map(|operation| operation.board_item_id.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

async fn imported_items(
    board: &AsyncDaemonDb,
    operations: &[ExternalSyncOperation],
) -> Vec<TaskBoardItem> {
    let mut items = Vec::new();
    for id in imported_item_ids(operations) {
        items.push(
            board
                .item_snapshot(&id)
                .await
                .expect("load imported item")
                .item,
        );
    }
    items
}

fn pull_task(number: u64, kind: TaskBoardWorkflowKind, head: &str, author: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, format!("{REPOSITORY}#{number}"))
            .with_url(format!("https://github.com/{REPOSITORY}/pull/{number}")),
        title: format!("Pull request {number}"),
        body: String::new(),
        status: TaskBoardStatus::Inbox,
        project_id: Some(REPOSITORY.to_owned()),
        updated_at: Some("2026-05-14T03:00:00Z".to_owned()),
        workflow_kind: kind,
        pr_head_revision: Some(head.to_owned()),
        pr_author: Some(author.to_owned()),
        ..ExternalTask::default()
    }
}

fn pull_only() -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
        status: None,
    }
}

#[tokio::test]
async fn dependency_and_review_pull_requests_import_once_with_identity() {
    let temp = tempdir().expect("tempdir");
    let board = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        vec![
            pull_task(
                12,
                TaskBoardWorkflowKind::PrFix,
                "dep-head",
                "renovate[bot]",
            ),
            pull_task(20, TaskBoardWorkflowKind::PrReview, "rev-head", "alice"),
        ],
    ))];

    let operations = sync_external_tasks(&board, pull_only(), &clients)
        .await
        .expect("discovery pull");

    assert_eq!(operations.len(), 2);
    let items = imported_items(&board, &operations).await;
    assert_eq!(items.len(), 2, "each pull request imports exactly once");

    let dependency = items
        .iter()
        .find(|item| item.workflow_kind == TaskBoardWorkflowKind::PrFix)
        .expect("dependency ticket");
    assert_eq!(
        dependency.workflow.pr_head_revision.as_deref(),
        Some("dep-head")
    );
    assert_eq!(
        dependency.workflow.pr_author.as_deref(),
        Some("renovate[bot]")
    );
    assert_eq!(dependency.execution_repository.as_deref(), Some(REPOSITORY));
    assert!(dependency.external_refs.iter().any(|reference| {
        reference.provider == ExternalRefProvider::GitHub
            && reference.external_id == format!("{REPOSITORY}#12")
            && reference.url.as_deref() == Some("https://github.com/acme/widgets/pull/12")
    }));

    let review = items
        .iter()
        .find(|item| item.workflow_kind == TaskBoardWorkflowKind::PrReview)
        .expect("review ticket");
    assert_eq!(
        review.workflow.pr_head_revision.as_deref(),
        Some("rev-head")
    );
    assert_eq!(review.workflow.pr_author.as_deref(), Some("alice"));
    assert_eq!(
        review.external_refs[0].external_id,
        format!("{REPOSITORY}#20")
    );
}

#[tokio::test]
async fn combined_intent_folds_dependency_and_review_into_one_ticket() {
    let temp = tempdir().expect("tempdir");
    let board = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    // A ticket already discovered as a dependency update becomes a review
    // request too. The pull must reconcile onto the one ticket, union the
    // intents, and refresh its live provider head without replacing the
    // stable author or duplicating the ticket.
    let mut existing = github_review_request_item(
        "task-combined-7",
        &format!("{REPOSITORY}#7"),
        TaskBoardStatus::Inbox,
    );
    existing.workflow_kind = TaskBoardWorkflowKind::PrFix;
    existing.workflow.pr_head_revision = Some("frozen-head".to_owned());
    existing.workflow.pr_author = Some("renovate[bot]".to_owned());
    board
        .create_item(existing)
        .await
        .expect("seed dependency ticket");

    let review: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(
            ExternalProvider::GitHub,
            vec![pull_task(
                7,
                TaskBoardWorkflowKind::PrReview,
                "advanced-head",
                "alice",
            )],
        )
        .with_scope(REPOSITORY),
    )];
    sync_external_tasks(&board, pull_only(), &review)
        .await
        .expect("review discovery pull");

    let ticket = board
        .item_snapshot("task-combined-7")
        .await
        .expect("load combined ticket")
        .item;
    assert_eq!(ticket.workflow_kind, TaskBoardWorkflowKind::PrFixReview);
    assert_eq!(
        ticket.workflow.pr_head_revision.as_deref(),
        Some("advanced-head"),
        "reconciliation refreshes the live provider head"
    );
    assert_eq!(ticket.workflow.pr_author.as_deref(), Some("renovate[bot]"));
}

#[tokio::test]
async fn authoritative_complete_pull_closes_an_omitted_review_ticket() {
    let temp = tempdir().expect("tempdir");
    let board = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    board
        .create_item(github_review_request_item(
            "task-review-30",
            &format!("{REPOSITORY}#30"),
            TaskBoardStatus::Inbox,
        ))
        .await
        .expect("seed open review ticket");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, Vec::new())
            .with_scope(REPOSITORY)
            .with_authoritative_review_inbox(),
    )];

    sync_external_tasks(&board, pull_only(), &clients)
        .await
        .expect("authoritative pull");

    let ticket = board
        .item_snapshot("task-review-30")
        .await
        .expect("load review ticket")
        .item;
    assert_eq!(
        ticket.status,
        TaskBoardStatus::Done,
        "a complete authoritative inbox closes the omitted review request"
    );
}

#[tokio::test]
async fn non_authoritative_pull_preserves_an_omitted_open_review_ticket() {
    let temp = tempdir().expect("tempdir");
    let board = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    board
        .create_item(github_review_request_item(
            "task-review-31",
            &format!("{REPOSITORY}#31"),
            TaskBoardStatus::Inbox,
        ))
        .await
        .expect("seed open review ticket");
    // An incomplete pull reports itself non-authoritative, the same signal the
    // real inbox client raises after a query fails, so the omitted ticket must
    // survive rather than being marked Done behind the gap.
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        FakeSyncClient::new(ExternalProvider::GitHub, Vec::new()).with_scope(REPOSITORY),
    )];

    sync_external_tasks(&board, pull_only(), &clients)
        .await
        .expect("non-authoritative pull");

    let ticket = board
        .item_snapshot("task-review-31")
        .await
        .expect("load review ticket")
        .item;
    assert_eq!(
        ticket.status,
        TaskBoardStatus::Inbox,
        "an incomplete pull preserves the omitted open review request"
    );
}
