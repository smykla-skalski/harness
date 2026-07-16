use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use super::*;
use crate::errors::CliErrorKind;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{ExternalRefProvider, ExternalRefSyncState, TaskBoardSyncConflict};

#[tokio::test]
async fn local_failure_preserves_partial_batch_and_stops_later_scopes() {
    let store = EvidenceStore::with_create_limit(1);
    let first_calls = Arc::new(AtomicUsize::new(0));
    let later_calls = Arc::new(AtomicUsize::new(0));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![
        Box::new(PullClient::new(
            "scope/primary",
            vec![
                pulled_task("remote-first", "First"),
                pulled_task("remote-failing", "Failing"),
            ],
            Arc::clone(&first_calls),
        )),
        Box::new(PullClient::new(
            "scope/later",
            vec![pulled_task("remote-later", "Later")],
            Arc::clone(&later_calls),
        )),
    ];

    let batch = sync_external_tasks_scoped(&store, pull_options(), &clients)
        .await
        .expect("local failure should return batch evidence");

    assert_eq!(first_calls.load(Ordering::SeqCst), 1);
    assert_eq!(later_calls.load(Ordering::SeqCst), 0);
    assert_eq!(store.failure_completions.load(Ordering::SeqCst), 1);
    assert_eq!(batch.operations.len(), 1);
    assert!(batch.operations[0].applied);
    assert_eq!(batch.scope_outcomes.len(), 1);
    assert_eq!(
        batch.scope_outcomes[0].error_code.as_deref(),
        Some("WORKFLOW_IO")
    );
    let error = batch
        .into_completed()
        .expect_err("terminal local failure must fail completion");
    assert_eq!(error.code(), "WORKFLOW_IO");
    assert!(error.message().contains("local create persistence failed"));
}

#[tokio::test]
async fn local_and_finalization_failures_are_both_preserved() {
    let mut store = EvidenceStore::with_create_limit(0);
    store.completion_error = Some("scope finalization failed");
    store.completion_details = Some("scope finalization detail");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(PullClient::new(
        "scope/failing",
        vec![pulled_task("remote-failing", "Failing")],
        Arc::new(AtomicUsize::new(0)),
    ))];

    let batch = sync_external_tasks_scoped(&store, pull_options(), &clients)
        .await
        .expect("combined failure should return batch evidence");

    assert_eq!(store.failure_completions.load(Ordering::SeqCst), 1);
    let evidence = batch.scope_outcomes[0]
        .error
        .as_deref()
        .expect("failed scope evidence");
    assert!(evidence.contains("local create persistence failed"));
    assert!(evidence.contains("scope finalization failed"));
    assert!(evidence.contains("scope finalization detail"));
    let error = batch
        .into_completed()
        .expect_err("combined terminal failure");
    assert_eq!(error.code(), "WORKFLOW_IO");
    assert!(error.message().contains("local create persistence failed"));
    assert!(
        error
            .details()
            .is_some_and(|details| details.contains("scope finalization failed"))
    );
    assert!(
        error
            .details()
            .is_some_and(|details| details.contains("scope finalization detail"))
    );
}

#[tokio::test]
async fn applied_pull_evidence_survives_conflict_cleanup_failure() {
    let item = linked_item("task-cleanup", "Local title");
    let mut store = EvidenceStore::with_items(vec![item.clone()]);
    store.update_behavior = UpdateBehavior::Apply;
    store.conflict_error = Some("conflict cleanup failed");
    let task = remote_task("Remote title");
    let mut operations = Vec::new();

    let error = reconcile_existing_item(
        &store,
        ExternalSyncOptions {
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::PreferRemote,
            dry_run: false,
            ..ExternalSyncOptions::default()
        },
        ExternalProvider::Todoist,
        &item,
        task,
        &mut operations,
    )
    .await
    .expect_err("cleanup failure");

    assert!(error.message().contains("conflict cleanup failed"));
    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert!(operations[0].applied);
}

#[tokio::test]
async fn converged_concurrent_pull_emits_no_applied_evidence() {
    let expected = linked_item("task-converged", "Local title");
    let task = remote_task("Remote title");
    let mut latest = expected.clone();
    latest.title.clone_from(&task.title);
    latest.external_refs[0].sync_state = Some(sync_state(&task));
    let mut store = EvidenceStore::with_items(vec![latest]);
    store.update_behavior = UpdateBehavior::Concurrent;
    let mut operations = Vec::new();

    reconcile_existing_item(
        &store,
        ExternalSyncOptions {
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            ..ExternalSyncOptions::default()
        },
        ExternalProvider::Todoist,
        &expected,
        task,
        &mut operations,
    )
    .await
    .expect("latest item already converged");

    assert!(operations.is_empty());
}

#[tokio::test]
async fn stale_review_failure_emits_no_applied_evidence() {
    let item = stale_review_item();
    let mut store = EvidenceStore::with_items(vec![item.clone()]);
    store.update_behavior = UpdateBehavior::Fail("stale review persistence failed");
    let client = ReviewClient;
    let mut operations = Vec::new();

    let error = reconcile_stale_github_review_requests(
        &store,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            dry_run: false,
            ..ExternalSyncOptions::default()
        },
        &client,
        &[item],
        &[],
        &mut operations,
    )
    .await
    .expect_err("stale review persistence failure");

    assert!(error.message().contains("stale review persistence failed"));
    assert!(operations.is_empty());
}

#[derive(Clone, Copy)]
enum UpdateBehavior {
    Apply,
    Concurrent,
    Fail(&'static str),
}

struct EvidenceStore {
    items: Mutex<Vec<TaskBoardItem>>,
    successful_creates: usize,
    create_calls: AtomicUsize,
    update_behavior: UpdateBehavior,
    conflict_error: Option<&'static str>,
    completion_error: Option<&'static str>,
    completion_details: Option<&'static str>,
    failure_completions: AtomicUsize,
}

impl TaskBoardExternalCreateStore for EvidenceStore {}

impl EvidenceStore {
    fn with_create_limit(successful_creates: usize) -> Self {
        Self {
            items: Mutex::new(Vec::new()),
            successful_creates,
            create_calls: AtomicUsize::new(0),
            update_behavior: UpdateBehavior::Apply,
            conflict_error: None,
            completion_error: None,
            completion_details: None,
            failure_completions: AtomicUsize::new(0),
        }
    }

    fn with_items(items: Vec<TaskBoardItem>) -> Self {
        Self {
            items: Mutex::new(items),
            successful_creates: usize::MAX,
            create_calls: AtomicUsize::new(0),
            update_behavior: UpdateBehavior::Apply,
            conflict_error: None,
            completion_error: None,
            completion_details: None,
            failure_completions: AtomicUsize::new(0),
        }
    }
}

#[async_trait]
impl TaskBoardSyncStore for EvidenceStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(self.items.lock().expect("items").clone())
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(self.items.lock().expect("items").clone())
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        let call = self.create_calls.fetch_add(1, Ordering::SeqCst);
        if call >= self.successful_creates {
            return Err(CliErrorKind::workflow_io("local create persistence failed").into());
        }
        self.items.lock().expect("items").push(item.clone());
        Ok(item)
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        match self.update_behavior {
            UpdateBehavior::Apply => {
                let mut updated = expected_item.clone();
                apply_patch(&mut updated, patch);
                let mut items = self.items.lock().expect("items");
                if let Some(item) = items.iter_mut().find(|item| item.id == updated.id) {
                    item.clone_from(&updated);
                }
                Ok(updated)
            }
            UpdateBehavior::Concurrent => {
                Err(CliErrorKind::concurrent_modification("concurrent test update").into())
            }
            UpdateBehavior::Fail(message) => Err(CliErrorKind::workflow_io(message).into()),
        }
    }

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        self.items
            .lock()
            .expect("items")
            .iter()
            .find(|item| item.id == item_id)
            .cloned()
            .map(|item| TaskBoardSyncItemSnapshot::new(item, 1))
            .ok_or_else(|| CliErrorKind::workflow_io("missing test item").into())
    }

    async fn provider_scope_state(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        Ok(ExternalProviderScopeState::default())
    }

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        _now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        Ok(ExternalProviderScopeAttemptDecision::Started(
            ExternalProviderScopeAttempt::new(
                provider,
                scope_id.to_owned(),
                format!("test:{scope_id}"),
                true,
            ),
        ))
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.failure_completions.fetch_add(1, Ordering::SeqCst);
        if let Some(message) = self.completion_error {
            let mut error: CliError = CliErrorKind::workflow_io(message).into();
            if let Some(details) = self.completion_details {
                error = error.with_details(details);
            }
            return Err(error);
        }
        Ok(ExternalProviderScopeState::default())
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        self.conflict_error.map_or(Ok(()), |message| {
            Err(CliErrorKind::workflow_io(message).into())
        })
    }

    async fn supersede_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        self.conflict_error.map_or(Ok(()), |message| {
            Err(CliErrorKind::workflow_io(message).into())
        })
    }
}

struct PullClient {
    scope_id: &'static str,
    tasks: Vec<ExternalTask>,
    calls: Arc<AtomicUsize>,
}

impl PullClient {
    fn new(scope_id: &'static str, tasks: Vec<ExternalTask>, calls: Arc<AtomicUsize>) -> Self {
        Self {
            scope_id,
            tasks,
            calls,
        }
    }
}

#[async_trait]
impl ExternalSyncClient for PullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn scope_id(&self) -> String {
        self.scope_id.into()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(self.tasks.clone())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only test client")
    }
}

struct ReviewClient;

#[async_trait]
impl ExternalSyncClient for ReviewClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn allows_push(&self) -> bool {
        false
    }

    fn authoritative_review_inbox(&self) -> bool {
        true
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        unreachable!("direct stale-review test")
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only review client")
    }
}

fn pull_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        direction: ExternalSyncDirection::Pull,
        dry_run: false,
        ..ExternalSyncOptions::default()
    }
}

fn pulled_task(external_id: &str, title: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, external_id),
        title: title.into(),
        body: String::new(),
        status: TaskBoardStatus::Backlog,
        project_id: None,
        updated_at: Some("2026-07-16T10:00:00Z".into()),
    }
}

fn linked_item(id: &str, title: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        title.into(),
        "Body".into(),
        "2026-07-16T10:00:00Z".into(),
    );
    let mut reference =
        ExternalTaskRef::new(ExternalProvider::Todoist, "remote-linked").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Base title".into()),
        body: Some("Body".into()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: None,
        updated_at: Some("2026-07-16T10:00:00Z".into()),
        synced_at: Some("2026-07-16T10:00:00Z".into()),
    });
    item.external_refs = vec![reference];
    item
}

fn remote_task(title: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, "remote-linked"),
        title: title.into(),
        body: "Body".into(),
        status: TaskBoardStatus::Backlog,
        project_id: None,
        updated_at: Some("2026-07-16T10:05:00Z".into()),
    }
}

fn sync_state(task: &ExternalTask) -> ExternalRefSyncState {
    ExternalRefSyncState {
        title: Some(task.title.clone()),
        body: Some(task.body.clone()),
        status: Some(task.status),
        project_id: task.project_id.clone(),
        updated_at: task.updated_at.clone(),
        synced_at: Some("2026-07-16T10:05:00Z".into()),
    }
}

fn stale_review_item() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "task-stale-review".into(),
        "Review".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    );
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    let mut reference = ExternalTaskRef::new(ExternalProvider::GitHub, "org/repository#17")
        .with_url("https://example.test/org/repository/pull/17")
        .into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        status: Some(TaskBoardStatus::Backlog),
        ..ExternalRefSyncState::default()
    });
    item.external_refs = vec![reference];
    item
}
