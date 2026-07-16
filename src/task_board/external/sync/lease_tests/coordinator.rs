use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;

use super::support::DurableCreateStore;
use super::*;
use crate::task_board::ExternalProviderCapabilities;

#[derive(Default)]
struct ProviderCalls {
    pulls: AtomicUsize,
    updates: AtomicUsize,
    deletes: AtomicUsize,
}

struct FenceClient {
    calls: Arc<ProviderCalls>,
}

#[async_trait]
impl ExternalSyncClient for FenceClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn scope_id(&self) -> String {
        "provider-project".into()
    }

    fn scope_for_item(&self, _item: &TaskBoardItem) -> String {
        self.scope_id()
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        ExternalProviderCapabilities::with_update_fields(vec![ExternalSyncField::Title])
    }

    fn allows_delete(&self) -> bool {
        true
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        self.calls.pulls.fetch_add(1, Ordering::SeqCst);
        Ok(Vec::new())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("linked-item fence tests do not create provider tasks")
    }

    async fn update_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        _update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        self.calls.updates.fetch_add(1, Ordering::SeqCst);
        Ok(ExternalUpdateOutcome::Applied {
            reference: reference.clone(),
            provider_revision: Some("provider-revision-2".into()),
        })
    }

    async fn delete_task(
        &self,
        _item: &TaskBoardItem,
        _reference: &ExternalTaskRef,
    ) -> Result<(), CliError> {
        self.calls.deletes.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[tokio::test]
async fn coordinator_cancellation_stops_pull_before_provider_call() {
    let (store, calls, batch) = cancelled_sync(
        unlinked_item("task-pull-fence"),
        pull_options(ExternalProvider::Todoist),
    )
    .await;

    assert_cancelled_scope(&store, &batch, 1);
    assert_eq!(calls.pulls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn coordinator_cancellation_stops_linked_update_before_provider_call() {
    let (store, calls, batch) = cancelled_sync(
        linked_item("task-update-fence", false),
        push_options(ExternalProvider::Todoist),
    )
    .await;

    assert_cancelled_scope(&store, &batch, 1);
    assert_eq!(calls.updates.load(Ordering::SeqCst), 0);
    assert_eq!(calls.deletes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn coordinator_cancellation_stops_delete_before_provider_call() {
    let (store, calls, batch) = cancelled_sync(
        linked_item("task-delete-fence", true),
        push_options(ExternalProvider::Todoist),
    )
    .await;

    assert_cancelled_scope(&store, &batch, 1);
    assert_eq!(calls.deletes.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn dry_run_pull_checks_coordinator_without_provider_attempt() {
    let mut options = pull_options(ExternalProvider::Todoist);
    options.dry_run = true;
    let (store, calls, batch) = cancelled_sync(unlinked_item("task-dry-run-fence"), options).await;

    assert_cancelled_scope(&store, &batch, 0);
    assert_eq!(calls.pulls.load(Ordering::SeqCst), 0);
    assert_eq!(
        *store.fence_order.lock().expect("fence order"),
        vec!["coordinator"]
    );
}

async fn cancelled_sync(
    item: TaskBoardItem,
    options: ExternalSyncOptions,
) -> (
    DurableCreateStore,
    Arc<ProviderCalls>,
    crate::task_board::external::ExternalSyncBatch,
) {
    let store = DurableCreateStore::coordinator_cancelled(item);
    let calls = Arc::new(ProviderCalls::default());
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FenceClient {
        calls: Arc::clone(&calls),
    })];
    let batch = sync_external_tasks_scoped(&store, options, &clients)
        .await
        .expect("coordinator cancellation retains scope evidence");
    (store, calls, batch)
}

fn assert_cancelled_scope(
    store: &DurableCreateStore,
    batch: &crate::task_board::external::ExternalSyncBatch,
    expected_releases: usize,
) {
    assert!(batch.terminal_error.is_some());
    assert!(batch.first_provider_failure.is_none());
    assert_eq!(store.failure_completions.load(Ordering::SeqCst), 0);
    assert_eq!(
        store.neutral_releases.load(Ordering::SeqCst),
        expected_releases
    );
    assert_eq!(store.coordinator_checks.load(Ordering::SeqCst), 1);
}

fn linked_item(id: &str, deleted: bool) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Current title".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    );
    item.project_id = Some("provider-project".into());
    item.deleted_at = deleted.then(|| "2026-07-16T12:00:00Z".into());
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-task");
    let mut core_reference = reference.into_core_ref();
    core_reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Previous title".into()),
        body: Some(String::new()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: Some("provider-project".into()),
        updated_at: Some("provider-revision-1".into()),
        synced_at: Some("2026-07-16T10:00:00Z".into()),
    });
    item.external_refs.push(core_reference);
    item
}
