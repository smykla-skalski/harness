use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalCreateRequest,
    ExternalProviderScopeIdentity,
};
use crate::task_board::{
    ExternalProvider, ExternalProviderCapabilities, ExternalRefSyncState, ExternalRevisionUpdate,
    ExternalSyncAction, ExternalSyncClient, ExternalSyncConflictPolicy, ExternalSyncDirection,
    ExternalSyncField, ExternalSyncOptions, ExternalTask, ExternalTaskRef, ExternalTaskUpdate,
    ExternalUpdateOutcome, TaskBoardExternalCreateIntentState, TaskBoardItem, TaskBoardStatus,
    sync_external_tasks,
};

#[tokio::test]
async fn newly_created_done_item_is_linked_then_closed() {
    let (_temp, board) = board_with_done_item().await;
    let client = CreateDoneClient::with_status_updates();
    let pushes = client.pushes.clone();
    let updates = client.updates.clone();

    let operations = sync(&board, client).await.expect("push Done item");

    assert_eq!(pushes.lock().expect("push log").as_slice(), ["done-1"]);
    assert_eq!(
        updates.lock().expect("update log").as_slice(),
        [CapturedUpdate {
            changed_fields: vec![ExternalSyncField::Status],
            precondition_updated_at: Some("provider-revision-1".into()),
        }]
    );
    assert_eq!(operations.len(), 2);
    assert_eq!(
        operations[0].changed_fields,
        vec![
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Project,
        ]
    );
    assert_eq!(
        operations[1].changed_fields,
        vec![ExternalSyncField::Status]
    );
    let state = stored_sync_state(&board).await;
    assert_eq!(state.status, Some(TaskBoardStatus::Done));
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-2"));
    assert_eq!(state.project_id.as_deref(), Some("provider-project"));
}

#[tokio::test]
async fn failed_close_keeps_link_and_backoff_does_not_create_duplicate() {
    let (_temp, board) = board_with_done_item().await;
    let client = CreateDoneClient::with_status_updates().fail_next_update();
    let pushes = client.pushes.clone();
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    sync_external_tasks(&board, push_options(), &clients)
        .await
        .expect_err("first close should fail");

    assert_eq!(pushes.lock().expect("push log").as_slice(), ["done-1"]);
    let state = stored_sync_state(&board).await;
    assert_eq!(state.status, Some(TaskBoardStatus::Backlog));
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-1"));
    assert_eq!(
        board
            .task_board_item("done-1")
            .await
            .expect("linked item after failure")
            .external_refs
            .len(),
        1
    );

    let operations = sync_external_tasks(&board, push_options(), &clients)
        .await
        .expect("backoff skips the linked retry");

    assert_eq!(pushes.lock().expect("push log").as_slice(), ["done-1"]);
    assert!(operations.is_empty());
    let updates = updates.lock().expect("update log");
    assert_eq!(updates.len(), 1);
    assert!(updates.iter().all(|update| {
        update.precondition_updated_at.as_deref() == Some("provider-revision-1")
    }));
    let state = stored_sync_state(&board).await;
    assert_eq!(state.status, Some(TaskBoardStatus::Backlog));
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-1"));
}

#[tokio::test]
async fn create_only_provider_reports_done_status_as_unsupported() {
    let (_temp, board) = board_with_done_item().await;

    let operations = sync(&board, CreateDoneClient::creates_only())
        .await
        .expect("link item without status support");

    assert_eq!(operations.len(), 2);
    assert_eq!(operations[0].action, ExternalSyncAction::Push);
    assert_eq!(
        operations[0].changed_fields,
        vec![
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Project,
        ]
    );
    assert_eq!(
        operations[1].unsupported_fields,
        vec![ExternalSyncField::Status]
    );
    assert!(!operations[1].applied);
    let state = stored_sync_state(&board).await;
    assert_eq!(state.status, Some(TaskBoardStatus::Backlog));
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-1"));
    assert_eq!(state.project_id.as_deref(), Some("provider-project"));
}

#[tokio::test]
async fn done_create_and_close_preserve_exact_unknown_provider_revisions() {
    let (_temp, board) = board_with_done_item().await;
    let client = CreateDoneClient::with_status_updates().without_revisions();
    let scope_id = ExternalProviderScopeIdentity::for_client(&client)
        .scope_id()
        .to_owned();
    let updates = client.updates.clone();

    let operations = sync(&board, client)
        .await
        .expect("push Done item with unknown revisions");

    assert_eq!(operations.len(), 2);
    assert!(operations.iter().all(|operation| operation.applied));
    assert_eq!(
        updates.lock().expect("update log").as_slice(),
        [CapturedUpdate {
            changed_fields: vec![ExternalSyncField::Status],
            precondition_updated_at: None,
        }]
    );
    let state = stored_sync_state(&board).await;
    assert_eq!(state.status, Some(TaskBoardStatus::Done));
    assert_eq!(state.updated_at, None);
    let receipt = board
        .task_board_external_create_receipt("done-1", ExternalProvider::Todoist)
        .await
        .expect("create receipt")
        .expect("attached create receipt");
    let TaskBoardExternalCreateIntentState::Attached(receipt) = receipt.state else {
        panic!("create receipt must be attached");
    };
    assert_eq!(receipt.evidence.outcome.provider_revision, None);
    assert_eq!(
        receipt
            .evidence
            .provider_baseline
            .sync_state
            .as_ref()
            .expect("provider baseline")
            .updated_at,
        None
    );
    assert_eq!(
        board
            .task_board_provider_scope_state(ExternalProvider::Todoist, &scope_id)
            .await
            .expect("scope state")
            .base_revision,
        None
    );
}

async fn sync(
    board: &AsyncDaemonDb,
    client: CreateDoneClient,
) -> Result<Vec<crate::task_board::ExternalSyncOperation>, CliError> {
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];
    sync_external_tasks(board, push_options(), &clients).await
}

fn push_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(ExternalProvider::Todoist),
        direction: ExternalSyncDirection::Push,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
        status: None,
    }
}

async fn board_with_done_item() -> (tempfile::TempDir, AsyncDaemonDb) {
    let temp = tempdir().expect("tempdir");
    let board = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    let mut item = TaskBoardItem::new(
        "done-1".to_owned(),
        "Finished task".to_owned(),
        "Completed locally.".to_owned(),
        "2026-07-16T00:00:00Z".to_owned(),
    );
    item.status = TaskBoardStatus::Done;
    item.project_id = Some("provider-project".into());
    board
        .create_task_board_item(item)
        .await
        .expect("create Done item");
    (temp, board)
}

async fn stored_sync_state(board: &AsyncDaemonDb) -> ExternalRefSyncState {
    board
        .task_board_item("done-1")
        .await
        .expect("stored item")
        .external_refs
        .first()
        .expect("external reference")
        .sync_state
        .clone()
        .expect("sync state")
}

#[derive(Debug, PartialEq, Eq)]
struct CapturedUpdate {
    changed_fields: Vec<ExternalSyncField>,
    precondition_updated_at: Option<String>,
}

struct CreateDoneClient {
    capabilities: ExternalProviderCapabilities,
    pushes: Arc<Mutex<Vec<String>>>,
    updates: Arc<Mutex<Vec<CapturedUpdate>>>,
    fail_next_update: AtomicBool,
    create_revision: Option<String>,
    update_revision: Option<String>,
}

impl CreateDoneClient {
    fn with_status_updates() -> Self {
        Self::new(ExternalProviderCapabilities::with_update_fields([
            ExternalSyncField::Status,
        ]))
    }

    fn creates_only() -> Self {
        Self::new(ExternalProviderCapabilities::creates_only())
    }

    fn new(capabilities: ExternalProviderCapabilities) -> Self {
        Self {
            capabilities,
            pushes: Arc::new(Mutex::new(Vec::new())),
            updates: Arc::new(Mutex::new(Vec::new())),
            fail_next_update: AtomicBool::new(false),
            create_revision: Some("provider-revision-1".into()),
            update_revision: Some("provider-revision-2".into()),
        }
    }

    fn fail_next_update(self) -> Self {
        self.fail_next_update.store(true, Ordering::SeqCst);
        self
    }

    fn without_revisions(mut self) -> Self {
        self.create_revision = None;
        self.update_revision = None;
        self
    }
}

#[async_trait]
impl ExternalSyncClient for CreateDoneClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
        Some(self)
    }

    fn scope_id(&self) -> String {
        "provider-project".into()
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        self.capabilities.clone()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(Vec::new())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("durable create admission must use create_started")
    }

    async fn update_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        self.updates
            .lock()
            .expect("update log")
            .push(CapturedUpdate {
                changed_fields: update.changed_fields,
                precondition_updated_at: update.precondition_updated_at,
            });
        if self.fail_next_update.swap(false, Ordering::SeqCst) {
            return Err(CliErrorKind::workflow_io("simulated status update failure").into());
        }
        Ok(ExternalUpdateOutcome::Applied {
            reference: reference.clone(),
            provider_revision: ExternalRevisionUpdate::from_new_revision(
                self.update_revision.clone(),
            ),
        })
    }
}

#[async_trait]
impl ExternalCreateRecoveryClient for CreateDoneClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn supports_target(&self, provider_target: &str) -> bool {
        provider_target == "provider-project"
    }

    async fn create_started(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError> {
        lease.renew().await?;
        self.pushes
            .lock()
            .expect("push log")
            .push(request.item_id().into());
        Ok(task_from_request(request, self.create_revision.clone()))
    }

    async fn recover_existing(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError> {
        lease.renew().await?;
        Ok(ExternalCreateProbe::Found(Box::new(task_from_request(
            request,
            self.create_revision.clone(),
        ))))
    }
}

fn task_from_request(request: &ExternalCreateRequest, updated_at: Option<String>) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(
            ExternalProvider::Todoist,
            format!("remote-{}", request.item_id()),
        ),
        title: request.title().into(),
        body: request.body().into(),
        status: TaskBoardStatus::Backlog,
        project_id: Some(request.provider_target().into()),
        updated_at,
        ..ExternalTask::default()
    }
}
