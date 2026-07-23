use async_trait::async_trait;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::ExternalProviderScopeAttemptDecision;
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalRefSyncState, ExternalSyncAction,
    ExternalSyncClient, ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncOptions,
    ExternalTask, ExternalTaskRef, TaskBoardConflictState, TaskBoardItem, TaskBoardStatus,
    TaskBoardSyncConflict,
};

#[tokio::test]
async fn provider_scope_failure_backoff_is_isolated_and_reset_by_success() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");

    let first_attempt = begin_attempt(&db, "acme/widgets", "2026-07-16T10:00:00Z").await;
    let first = db
        .complete_task_board_provider_scope_failure(&first_attempt, "2026-07-16T10:00:00Z")
        .await
        .expect("first failure");
    let second_attempt = begin_attempt(&db, "acme/widgets", "2026-07-16T10:00:31Z").await;
    let second = db
        .complete_task_board_provider_scope_failure(&second_attempt, "2026-07-16T10:00:31Z")
        .await
        .expect("second failure");
    let other = db
        .task_board_provider_scope_state(ExternalProvider::GitHub, "acme/tools")
        .await
        .expect("other scope");

    assert_eq!(first.failure_count, 1);
    assert_eq!(second.failure_count, 2);
    assert!(second.backoff_until > first.backoff_until);
    assert_eq!(other.failure_count, 0);

    let success_attempt = begin_attempt(&db, "acme/widgets", "2026-07-16T10:02:32Z").await;
    db.complete_task_board_provider_scope_success(
        &success_attempt,
        Some("provider-revision-2"),
        "2026-07-16T10:02:32Z",
    )
    .await
    .expect("success");
    let push_attempt = begin_attempt(&db, "acme/widgets", "2026-07-16T10:03:00Z").await;
    db.complete_task_board_provider_scope_success(&push_attempt, None, "2026-07-16T10:03:00Z")
        .await
        .expect("push-only success");
    let reset = db
        .task_board_provider_scope_state(ExternalProvider::GitHub, "acme/widgets")
        .await
        .expect("reset scope");
    assert_eq!(reset.failure_count, 0);
    assert_eq!(reset.backoff_until, None);
    assert_eq!(reset.base_revision.as_deref(), Some("provider-revision-2"));
}

#[tokio::test]
async fn failed_provider_scope_does_not_block_a_successful_scope() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![
        Box::new(ScopedPullClient::failing("acme/broken")),
        Box::new(ScopedPullClient::successful(
            "acme/widgets",
            external_task("acme/widgets#17", TaskBoardStatus::Backlog),
        )),
    ];

    let batch =
        crate::task_board::external::sync_external_tasks_scoped(&db, pull_options(), &clients)
            .await
            .expect("partial batch");

    assert_eq!(batch.attempted_scope_count(), 2);
    assert_eq!(batch.succeeded_scope_count(), 1);
    assert_eq!(batch.failed_scope_count(), 1);
    assert_eq!(batch.operations.len(), 1);
    assert_eq!(
        db.task_board_provider_scope_state(
            ExternalProvider::GitHub,
            "v1:github:read:11:acme/broken",
        )
        .await
        .expect("failed scope")
        .failure_count,
        1
    );
    let successful = db
        .task_board_provider_scope_state(ExternalProvider::GitHub, "v1:github:read:12:acme/widgets")
        .await
        .expect("successful scope");
    assert_eq!(successful.failure_count, 0);
    assert_eq!(
        successful.base_revision.as_deref(),
        Some("2026-07-15T10:05:00Z")
    );
    assert!(
        db.list_task_board_items(None)
            .await
            .expect("items")
            .iter()
            .any(|item| item.title == "Remote task")
    );
}

#[tokio::test]
async fn a_mutual_parent_cycle_does_not_abort_the_batch_or_get_stuck() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let tasks = |unrelated_title: &str| {
        vec![
            cyclic_task("acme/widgets#100", "acme/widgets#101"),
            cyclic_task("acme/widgets#101", "acme/widgets#100"),
            ExternalTask {
                title: unrelated_title.into(),
                ..external_task("acme/widgets#102", TaskBoardStatus::Backlog)
            },
        ]
    };

    // First sync: neither cyclic item can resolve the other yet (both are
    // new in this same pass), so both import unlinked.
    sync_scoped(&db, tasks("Remote task"))
        .await
        .expect("first sync completes")
        .into_completed()
        .expect("first sync must not hard-error");

    // Second sync: both cyclic items now exist, so parent resolution finds
    // them. Whichever is processed first commits its link; the other's
    // attempt would create a cycle and must be skipped, not abort the batch.
    // The unrelated item's title also changes here, so an operation for it
    // only appears if the loop actually keeps going past the cyclic pair.
    let second = sync_scoped(&db, tasks("Remote task v2"))
        .await
        .expect("second sync completes")
        .into_completed()
        .expect("a parent cycle must not hard-error the whole batch");
    assert!(
        second
            .operations
            .iter()
            .any(|operation| operation.external_id.as_deref() == Some("acme/widgets#102")),
        "the unrelated item in the same batch must still sync"
    );

    let items = db.list_task_board_items(None).await.expect("items");
    let first_item = find_by_external_id(&items, "acme/widgets#100");
    let second_item = find_by_external_id(&items, "acme/widgets#101");
    assert!(
        !(first_item.parent_item_id.as_deref() == Some(second_item.id.as_str())
            && second_item.parent_item_id.as_deref() == Some(first_item.id.as_str())),
        "no cycle may ever be persisted"
    );

    // Third sync: the unresolved half of the cycle keeps getting retried
    // (and keeps failing validation), but the batch must stay healthy.
    sync_scoped(&db, tasks("Remote task v2"))
        .await
        .expect("third sync completes")
        .into_completed()
        .expect("re-syncing the same cycle must not get the batch stuck");
}

#[tokio::test]
async fn replacing_conflicts_keeps_current_fields_and_supersedes_removed_fields() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = TaskBoardItem::new(
        "task-1".into(),
        "Local title".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    );
    db.create_task_board_item(item).await.expect("create item");
    let title = conflict("conflict-title", "title");
    let status = conflict("conflict-status", "status");

    db.replace_open_task_board_sync_conflicts(
        "task-1",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        1,
        &[title.clone(), status],
    )
    .await
    .expect("record conflicts");
    assert_eq!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("list conflicts")
            .len(),
        2
    );

    db.replace_open_task_board_sync_conflicts(
        "task-1",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        1,
        &[title],
    )
    .await
    .expect("replace conflicts");
    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("list open conflicts");
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].field, "title");
}

#[tokio::test]
async fn pull_title_conflict_persists_three_way_values_without_overwriting_local_lane() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let mut item = TaskBoardItem::new(
        "task-sync".into(),
        "Local title".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.project_id = Some("acme/widgets".into());
    item.execution_repository = Some("acme/widgets".into());
    let mut reference =
        ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Base title".into()),
        body: Some(String::new()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: Some("acme/widgets".into()),
        updated_at: Some("2026-07-15T10:00:00Z".into()),
        synced_at: Some("2026-07-15T10:00:00Z".into()),
        labels: Vec::new(),
    });
    item.external_refs = vec![reference];
    db.create_task_board_item(item).await.expect("create item");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(ConflictPullClient)];

    let batch = crate::task_board::external::sync_external_tasks_scoped(
        &db,
        ExternalSyncOptions {
            status: None,
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
        },
        &clients,
    )
    .await
    .expect("sync batch");

    assert_eq!(batch.operations.len(), 1);
    assert_eq!(batch.operations[0].action, ExternalSyncAction::Conflict);
    assert_eq!(
        db.task_board_item("task-sync")
            .await
            .expect("current item")
            .title,
        "Local title"
    );
    assert_eq!(
        db.task_board_item("task-sync")
            .await
            .expect("current item")
            .status,
        TaskBoardStatus::InProgress
    );
    let conflicts = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].field, "title");
    assert_eq!(conflicts[0].base_value, serde_json::json!("Base title"));
    assert_eq!(conflicts[0].local_value, serde_json::json!("Local title"));
    assert_eq!(conflicts[0].remote_value, serde_json::json!("Remote title"));
}

#[tokio::test]
async fn remote_open_state_never_resets_an_internal_in_progress_lane() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let mut item = linked_item("task-open", TaskBoardStatus::InProgress);
    item.external_refs[0].sync_state = None;
    db.create_task_board_item(item).await.expect("create item");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(ScopedPullClient::successful(
        "acme/widgets",
        external_task("acme/widgets#18", TaskBoardStatus::Backlog),
    ))];

    crate::task_board::external::sync_external_tasks_scoped(&db, pull_options(), &clients)
        .await
        .expect("sync batch")
        .into_completed()
        .expect("completed batch");

    let current = db.task_board_item("task-open").await.expect("current item");
    assert_eq!(current.status, TaskBoardStatus::InProgress);
    assert!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("open conflicts")
            .is_empty()
    );
}

struct ConflictPullClient;

#[async_trait]
impl ExternalSyncClient for ConflictPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        "acme/widgets".into()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(vec![ExternalTask {
            reference: ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17"),
            title: "Remote title".into(),
            body: String::new(),
            status: TaskBoardStatus::Done,
            project_id: Some("acme/widgets".into()),
            updated_at: Some("2026-07-15T10:05:00Z".into()),
            ..ExternalTask::default()
        }])
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Err(CliErrorKind::workflow_io("pull-only test client").into())
    }
}

struct ScopedPullClient {
    scope_id: String,
    result: Result<Vec<ExternalTask>, &'static str>,
}

impl ScopedPullClient {
    fn failing(scope_id: &str) -> Self {
        Self {
            scope_id: scope_id.into(),
            result: Err("repository unavailable"),
        }
    }

    fn successful(scope_id: &str, task: ExternalTask) -> Self {
        Self {
            scope_id: scope_id.into(),
            result: Ok(vec![task]),
        }
    }

    fn successful_many(scope_id: &str, tasks: Vec<ExternalTask>) -> Self {
        Self {
            scope_id: scope_id.into(),
            result: Ok(tasks),
        }
    }
}

#[async_trait]
impl ExternalSyncClient for ScopedPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        self.scope_id.clone()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        self.result
            .clone()
            .map_err(|message| CliErrorKind::workflow_io(message).into())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only test client")
    }
}

fn pull_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: None,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
    }
}

async fn begin_attempt(
    db: &AsyncDaemonDb,
    scope_id: &str,
    now: &str,
) -> crate::task_board::external::ExternalProviderScopeAttempt {
    match db
        .begin_task_board_provider_scope_attempt(ExternalProvider::GitHub, scope_id, now)
        .await
        .expect("begin provider scope attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    }
}

fn external_task(external_id: &str, status: TaskBoardStatus) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, external_id),
        title: "Remote task".into(),
        body: String::new(),
        status,
        project_id: Some("acme/widgets".into()),
        updated_at: Some("2026-07-15T10:05:00Z".into()),
        ..ExternalTask::default()
    }
}

fn cyclic_task(external_id: &str, parent_external_id: &str) -> ExternalTask {
    ExternalTask {
        parent_reference: Some(ExternalTaskRef::new(
            ExternalProvider::GitHub,
            parent_external_id,
        )),
        ..external_task(external_id, TaskBoardStatus::Backlog)
    }
}

async fn sync_scoped(
    db: &AsyncDaemonDb,
    tasks: Vec<ExternalTask>,
) -> Result<crate::task_board::external::ExternalSyncBatch, CliError> {
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(
        ScopedPullClient::successful_many("acme/widgets", tasks),
    )];
    crate::task_board::external::sync_external_tasks_scoped(db, pull_options(), &clients).await
}

fn find_by_external_id<'a>(items: &'a [TaskBoardItem], external_id: &str) -> &'a TaskBoardItem {
    items
        .iter()
        .find(|item| {
            item.external_refs
                .iter()
                .any(|reference| reference.external_id == external_id)
        })
        .unwrap_or_else(|| panic!("no imported item for external id '{external_id}'"))
}

fn linked_item(id: &str, status: TaskBoardStatus) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Remote task".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    );
    item.status = status;
    item.project_id = Some("acme/widgets".into());
    item.execution_repository = Some("acme/widgets".into());
    let mut reference =
        ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#18").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Remote task".into()),
        body: Some(String::new()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: Some("acme/widgets".into()),
        updated_at: Some("2026-07-15T10:00:00Z".into()),
        synced_at: Some("2026-07-15T10:00:00Z".into()),
        labels: Vec::new(),
    });
    item.external_refs = vec![reference];
    item
}

fn conflict(conflict_id: &str, field: &str) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: conflict_id.into(),
        item_id: "task-1".into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: "acme/widgets#17".into(),
        field: field.into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision: 1,
        provider_revision: Some("provider-revision-1".into()),
        state: TaskBoardConflictState::Open,
    }
}
