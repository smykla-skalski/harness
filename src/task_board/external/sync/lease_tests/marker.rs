use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;

use super::client::DurableCreateClient;
use super::support::DurableCreateStore;
use super::*;

#[tokio::test]
async fn attached_marker_is_cleaned_and_retained_for_normal_reconciliation() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (store, client) = attached_marker_fixture("task-marker-attached", &calls).await;
    let mut operations = Vec::new();
    let mut follow_ups = Vec::new();

    let (tasks, recovered) = super::super::create_recovery::suppress_known_create_markers(
        &store,
        &client,
        vec![marked_task("task-marker-attached", "Provider edit")],
        &mut operations,
        &mut follow_ups,
        false,
    )
    .await
    .expect("attached marker handling");

    assert!(!recovered);
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].title, "Provider edit");
    assert_eq!(tasks[0].body, "Provider body");
    assert!(operations.is_empty());
    assert_eq!(follow_ups, vec![store.intent()]);
}

#[tokio::test]
async fn attached_marker_reconciles_provider_edits_once_without_recreating() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (store, _) = attached_marker_fixture("task-marker-reconcile", &calls).await;
    let before_record = store.record_calls.load(Ordering::SeqCst);
    let before_finalize = store.finalize_calls.load(Ordering::SeqCst);
    let mut task = marked_task("task-marker-reconcile", "Provider edit");
    task.reference = task
        .reference
        .with_url("https://todoist.com/showTask?id=remote-created");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(MarkerPullClient::new(task))];

    let first =
        sync_external_tasks_scoped(&store, pull_options(ExternalProvider::Todoist), &clients)
            .await
            .expect("reconcile linked attached marker");

    assert_eq!(first.operations.len(), 1);
    assert_eq!(first.operations[0].action, ExternalSyncAction::Pull);
    assert!(first.operations[0].applied);
    assert_eq!(store.update_calls.load(Ordering::SeqCst), 1);
    let updated = store.item.lock().expect("item").clone();
    assert_eq!(updated.title, "Provider edit");
    assert_eq!(updated.body, "Provider body");
    assert_eq!(
        updated.external_refs[0].url.as_deref(),
        Some("https://todoist.com/showTask?id=remote-created")
    );

    let second =
        sync_external_tasks_scoped(&store, pull_options(ExternalProvider::Todoist), &clients)
            .await
            .expect("repeat linked marker reconciliation");

    assert!(second.operations.is_empty());
    assert_eq!(store.update_calls.load(Ordering::SeqCst), 1);
    assert_eq!(store.record_calls.load(Ordering::SeqCst), before_record);
    assert_eq!(store.finalize_calls.load(Ordering::SeqCst), before_finalize);
}

#[tokio::test]
async fn attached_marker_without_its_local_reference_is_suppressed() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (store, client) = attached_marker_fixture("task-marker-unlinked", &calls).await;
    store.item.lock().expect("item").external_refs.clear();
    let mut operations = Vec::new();
    let mut follow_ups = Vec::new();

    let (tasks, recovered) = super::super::create_recovery::suppress_known_create_markers(
        &store,
        &client,
        vec![marked_task("task-marker-unlinked", "Provider edit")],
        &mut operations,
        &mut follow_ups,
        false,
    )
    .await
    .expect("matching attached marker remains suppressed after unlink");

    assert!(!recovered);
    assert!(tasks.is_empty());
    assert!(operations.is_empty());
    assert_eq!(follow_ups, vec![store.intent()]);
    assert!(store.item.lock().expect("item").external_refs.is_empty());

    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(MarkerPullClient::new(
        marked_task("task-marker-unlinked", "Provider edit"),
    ))];
    let options = ExternalSyncOptions {
        provider: Some(ExternalProvider::Todoist),
        direction: ExternalSyncDirection::Both,
        dry_run: false,
        ..ExternalSyncOptions::default()
    };
    for _ in 0..2 {
        let batch = sync_external_tasks_scoped(&store, options, &clients)
            .await
            .expect("repeat sync after unlink");
        assert!(batch.operations.is_empty());
        assert_eq!(batch.external_create_follow_ups, vec![store.intent()]);
        assert!(store.item.lock().expect("item").external_refs.is_empty());
        assert_eq!(
            *store.success_base_revision.lock().expect("base revision"),
            Some(Some("provider-revision-2".into()))
        );
    }
}

#[tokio::test]
async fn attached_marker_for_a_tombstone_is_suppressed_without_removing_its_ref() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (store, client) = attached_marker_fixture("task-marker-tombstone", &calls).await;
    store.item.lock().expect("item").deleted_at = Some("2026-07-16T12:00:00Z".into());
    let original_refs = store.item.lock().expect("item").external_refs.clone();
    let mut operations = Vec::new();
    let mut follow_ups = Vec::new();

    let (tasks, recovered) = super::super::create_recovery::suppress_known_create_markers(
        &store,
        &client,
        vec![marked_task("task-marker-tombstone", "Provider edit")],
        &mut operations,
        &mut follow_ups,
        false,
    )
    .await
    .expect("tombstoned attached marker remains recovery-owned");

    assert!(!recovered);
    assert!(tasks.is_empty());
    assert!(operations.is_empty());
    assert_eq!(follow_ups, vec![store.intent()]);
    assert_eq!(
        store.item.lock().expect("item").external_refs,
        original_refs
    );
}

#[tokio::test]
async fn attached_marker_with_a_different_remote_identity_fails_closed() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (store, client) = attached_marker_fixture("task-marker-mismatch", &calls).await;
    let mut task = marked_task("task-marker-mismatch", "Provider edit");
    task.reference.external_id = "different-remote".into();
    let mut operations = Vec::new();
    let mut follow_ups = Vec::new();

    let error = super::super::create_recovery::suppress_known_create_markers(
        &store,
        &client,
        vec![task],
        &mut operations,
        &mut follow_ups,
        false,
    )
    .await
    .expect_err("mismatched attached marker identity must fail closed");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(operations.is_empty());
    assert!(follow_ups.is_empty());
}

#[tokio::test]
async fn marker_preview_suppresses_pending_create_without_durable_writes() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut item = unlinked_item("task-marker-preview");
    item.project_id = Some("provider-project".into());
    let store = successful_store(item);
    let client = DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(&calls),
    );
    let scope = ExternalProviderScopeIdentity::for_client(&client);
    let decision = store
        .begin_external_create_intent(
            "task-marker-preview",
            ExternalProvider::Todoist,
            scope.scope_id(),
            "provider-project",
        )
        .await
        .expect("begin intent");
    assert!(matches!(decision, TaskBoardExternalCreateBegin::Started(_)));
    let mut operations = Vec::new();
    let mut follow_ups = Vec::new();

    let (tasks, recovered) = super::super::create_recovery::suppress_known_create_markers(
        &store,
        &client,
        vec![marked_task("task-marker-preview", "Provider edit")],
        &mut operations,
        &mut follow_ups,
        true,
    )
    .await
    .expect("dry-run marker handling");

    assert!(recovered);
    assert!(tasks.is_empty());
    assert!(operations.is_empty());
    assert!(follow_ups.is_empty());
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(store.record_calls.load(Ordering::SeqCst), 0);
    assert_eq!(store.finalize_calls.load(Ordering::SeqCst), 0);
    assert_eq!(store.supersede_calls.load(Ordering::SeqCst), 0);
    assert!(matches!(
        store.intent().state,
        TaskBoardExternalCreateIntentState::InFlight
    ));
}

async fn attached_marker_fixture(
    item_id: &str,
    calls: &Arc<AtomicUsize>,
) -> (DurableCreateStore, DurableCreateClient) {
    let mut item = unlinked_item(item_id);
    item.project_id = Some("provider-project".into());
    let store = successful_store(item);
    let client = DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(calls),
    );
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(DurableCreateClient::new(
        ExternalProvider::Todoist,
        "provider-project",
        Arc::clone(calls),
    ))];
    sync_external_tasks(&store, push_options(ExternalProvider::Todoist), &clients)
        .await
        .expect("attach provider create");
    (store, client)
}

fn marked_task(item_id: &str, title: &str) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, "remote-created"),
        title: title.into(),
        body: format!("Provider body\ncreate-key:create-key-{item_id}"),
        status: TaskBoardStatus::Backlog,
        project_id: Some("provider-project".into()),
        updated_at: Some("provider-revision-2".into()),
        ..ExternalTask::default()
    }
}

struct MarkerPullClient {
    task: ExternalTask,
}

impl MarkerPullClient {
    fn new(task: ExternalTask) -> Self {
        Self { task }
    }
}

#[async_trait]
impl ExternalSyncClient for MarkerPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
        Some(self)
    }

    fn scope_id(&self) -> String {
        "provider-project".into()
    }

    fn scope_for_item(&self, _item: &TaskBoardItem) -> String {
        self.scope_id()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(vec![self.task.clone()])
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("marker regression is pull-only")
    }
}

#[async_trait]
impl ExternalCreateRecoveryClient for MarkerPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn supports_target(&self, provider_target: &str) -> bool {
        provider_target == "provider-project"
    }

    async fn create_started(
        &self,
        _request: &ExternalCreateRequest,
        _lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError> {
        unreachable!("attached marker must not create")
    }

    async fn recover_existing(
        &self,
        _request: &ExternalCreateRequest,
        _lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError> {
        unreachable!("attached marker must not recover")
    }

    fn extract_create_key(&self, task: &mut ExternalTask) -> Result<Option<String>, CliError> {
        let Some((body, create_key)) = task.body.rsplit_once("\ncreate-key:") else {
            return Ok(None);
        };
        let body = body.to_owned();
        let create_key = create_key.to_owned();
        task.body = body;
        Ok(Some(create_key))
    }
}
