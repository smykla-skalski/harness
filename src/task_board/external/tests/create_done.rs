use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tempfile::tempdir;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    ExternalProvider, ExternalProviderCapabilities, ExternalSyncAction, ExternalSyncClient,
    ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncField, ExternalSyncOptions,
    ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome, TaskBoardItem,
    TaskBoardStatus, TaskBoardStore, sync_external_tasks,
};

#[tokio::test]
async fn newly_created_done_item_is_linked_then_closed() {
    let temp = tempdir().expect("tempdir");
    let board = board_with_done_item(temp.path());
    let client = CreateDoneClient::with_status_updates();
    let pushes = client.pushes.clone();
    let updates = client.updates.clone();

    let operations = sync(&board, client).await.expect("push Done item");

    assert_eq!(pushes.lock().expect("push log").as_slice(), ["done-1"]);
    assert_eq!(
        updates.lock().expect("update log").as_slice(),
        [vec![ExternalSyncField::Status]]
    );
    assert_eq!(operations.len(), 2);
    assert_eq!(
        operations[0].changed_fields,
        vec![ExternalSyncField::Title, ExternalSyncField::Body]
    );
    assert_eq!(
        operations[1].changed_fields,
        vec![ExternalSyncField::Status]
    );
    assert_eq!(stored_sync_status(&board), TaskBoardStatus::Done);
}

#[tokio::test]
async fn failed_close_keeps_link_and_retry_does_not_create_duplicate() {
    let temp = tempdir().expect("tempdir");
    let board = board_with_done_item(temp.path());
    let client = CreateDoneClient::with_status_updates().fail_next_update();
    let pushes = client.pushes.clone();
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    sync_external_tasks(&board, push_options(), &clients)
        .await
        .expect_err("first close should fail");

    assert_eq!(pushes.lock().expect("push log").as_slice(), ["done-1"]);
    assert_eq!(stored_sync_status(&board), TaskBoardStatus::Backlog);
    assert_eq!(
        board
            .get("done-1")
            .expect("linked item after failure")
            .external_refs
            .len(),
        1
    );

    sync_external_tasks(&board, push_options(), &clients)
        .await
        .expect("retry closes linked item");

    assert_eq!(pushes.lock().expect("push log").as_slice(), ["done-1"]);
    assert_eq!(updates.lock().expect("update log").len(), 2);
    assert_eq!(stored_sync_status(&board), TaskBoardStatus::Done);
}

#[tokio::test]
async fn create_only_provider_reports_done_status_as_unsupported() {
    let temp = tempdir().expect("tempdir");
    let board = board_with_done_item(temp.path());

    let operations = sync(&board, CreateDoneClient::creates_only())
        .await
        .expect("link item without status support");

    assert_eq!(operations.len(), 2);
    assert_eq!(operations[0].action, ExternalSyncAction::Push);
    assert_eq!(
        operations[0].changed_fields,
        vec![ExternalSyncField::Title, ExternalSyncField::Body]
    );
    assert_eq!(
        operations[1].unsupported_fields,
        vec![ExternalSyncField::Status]
    );
    assert!(!operations[1].applied);
    assert_eq!(stored_sync_status(&board), TaskBoardStatus::Backlog);
}

async fn sync(
    board: &TaskBoardStore,
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

fn board_with_done_item(path: &std::path::Path) -> TaskBoardStore {
    let board = TaskBoardStore::new(path.join("board"));
    let mut item = TaskBoardItem::new(
        "done-1".to_owned(),
        "Finished task".to_owned(),
        "Completed locally.".to_owned(),
        "2026-07-16T00:00:00Z".to_owned(),
    );
    item.status = TaskBoardStatus::Done;
    board
        .create("Finished task", "Completed locally.", item)
        .expect("create Done item");
    board
}

fn stored_sync_status(board: &TaskBoardStore) -> TaskBoardStatus {
    board
        .get("done-1")
        .expect("stored item")
        .external_refs
        .first()
        .expect("external reference")
        .sync_state
        .as_ref()
        .expect("sync state")
        .status
        .expect("sync status")
}

struct CreateDoneClient {
    capabilities: ExternalProviderCapabilities,
    pushes: Arc<Mutex<Vec<String>>>,
    updates: Arc<Mutex<Vec<Vec<ExternalSyncField>>>>,
    fail_next_update: AtomicBool,
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
        }
    }

    fn fail_next_update(self) -> Self {
        self.fail_next_update.store(true, Ordering::SeqCst);
        self
    }
}

#[async_trait]
impl ExternalSyncClient for CreateDoneClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        self.capabilities.clone()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(Vec::new())
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        self.pushes.lock().expect("push log").push(item.id.clone());
        Ok(ExternalTaskRef::new(
            ExternalProvider::Todoist,
            format!("remote-{}", item.id),
        ))
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
            .push(update.changed_fields);
        if self.fail_next_update.swap(false, Ordering::SeqCst) {
            return Err(CliErrorKind::workflow_io("simulated status update failure").into());
        }
        Ok(ExternalUpdateOutcome::Applied {
            reference: reference.clone(),
            provider_revision: None,
        })
    }
}
