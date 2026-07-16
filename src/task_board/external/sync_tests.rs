use std::sync::Mutex;

use async_trait::async_trait;
use tempfile::tempdir;

use super::*;
use crate::task_board::store::TaskBoardStore;
use crate::task_board::types::{ExternalRefSyncState, TaskBoardItem, TaskBoardStatus};

mod status_roundtrip_tests;

#[tokio::test]
async fn push_updates_existing_linked_remote_and_records_changed_fields() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Local title",
            "Old body",
            linked_item("task-1", "Local title", "Old body", TaskBoardStatus::Todo),
        )
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title, ExternalSyncField::Body],
        Vec::new(),
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Push);
    assert_eq!(operations[0].changed_fields, vec![ExternalSyncField::Title]);
    assert!(operations[0].applied);
    let updated = board.get("task-1").expect("load updated task");
    let state = updated.external_refs[0]
        .sync_state
        .as_ref()
        .expect("sync state");
    assert_eq!(state.title.as_deref(), Some("Local title"));
    assert_eq!(state.status, Some(TaskBoardStatus::Backlog));
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-2"));
}

#[tokio::test]
async fn both_direction_reports_conflict_by_default_without_writing() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Local edit",
            "Old body",
            linked_item("task-1", "Local edit", "Old body", TaskBoardStatus::Todo),
        )
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        vec![remote_task(
            "remote-1",
            "Remote edit",
            "Old body",
            TaskBoardStatus::Backlog,
        )],
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

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Conflict);
    assert_eq!(operations[0].changed_fields, vec![ExternalSyncField::Title]);
    assert!(!operations[0].applied);
    assert_eq!(board.get("task-1").expect("local task").title, "Local edit");
}

#[tokio::test]
async fn prefer_remote_applies_remote_conflict_side() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Local edit",
            "Old body",
            linked_item("task-1", "Local edit", "Old body", TaskBoardStatus::Todo),
        )
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        vec![remote_task(
            "remote-1",
            "Remote edit",
            "Old body",
            TaskBoardStatus::Backlog,
        )],
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::PreferRemote,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert_eq!(operations[0].changed_fields, vec![ExternalSyncField::Title]);
    assert_eq!(
        board.get("task-1").expect("local task").title,
        "Remote edit"
    );
}

#[tokio::test]
async fn prefer_local_updates_remote_conflict_side() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Local edit",
            "Old body",
            linked_item("task-1", "Local edit", "Old body", TaskBoardStatus::Todo),
        )
        .expect("create local task");
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        vec![remote_task(
            "remote-1",
            "Remote edit",
            "Old body",
            TaskBoardStatus::Backlog,
        )],
    );
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::PreferLocal,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Push);
    assert_eq!(operations[0].changed_fields, vec![ExternalSyncField::Title]);
    assert_eq!(
        *updates.lock().expect("updates"),
        vec![("remote-1".to_string(), vec![ExternalSyncField::Title])]
    );
}

#[tokio::test]
async fn linked_push_surfaces_conflict_when_precondition_fails() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Local edit",
            "Old body",
            linked_item("task-1", "Local edit", "Old body", TaskBoardStatus::Todo),
        )
        .expect("create local task");
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        Vec::new(),
    )
    .with_precondition_failure();
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert!(
        operations
            .iter()
            .any(|operation| operation.action == ExternalSyncAction::Conflict
                && operation.board_item_id.as_deref() == Some("task-1"))
    );
    assert!(updates.lock().expect("updates").is_empty());
}

#[tokio::test]
async fn linked_push_reports_provider_unsupported_fields() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Old title",
            "Old body",
            linked_item("task-1", "Old title", "Old body", TaskBoardStatus::Done),
        )
        .expect("create local task");
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        Vec::new(),
    ))];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(
        operations[0].unsupported_fields,
        vec![ExternalSyncField::Status]
    );
    assert!(!operations[0].applied);
}

#[tokio::test]
async fn scoped_sync_keeps_successful_repository_when_another_repository_fails() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![
        Box::new(ScopedPullClient::failing("acme/broken")),
        Box::new(ScopedPullClient::successful(
            "acme/widgets",
            ExternalTask {
                reference: ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17"),
                title: "Imported task".into(),
                body: String::new(),
                status: TaskBoardStatus::Backlog,
                project_id: Some("acme/widgets".into()),
                updated_at: Some("2026-07-15T10:00:00Z".into()),
            },
        )),
    ];

    let batch = sync_external_tasks_scoped(
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
    .expect("partial sync succeeds");

    assert_eq!(batch.attempted_scope_count(), 2);
    assert_eq!(batch.failed_scope_count(), 1);
    assert_eq!(batch.operations.len(), 1);
    let imported = board
        .list(None)
        .expect("list imported items")
        .into_iter()
        .find(|item| item.title == "Imported task")
        .expect("imported item");
    assert_eq!(
        imported.execution_repository.as_deref(),
        Some("acme/widgets")
    );
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
            .map_err(|message| crate::errors::CliErrorKind::workflow_io(message).into())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only test client")
    }
}

struct UpdateFakeSyncClient {
    provider: ExternalProvider,
    capabilities: ExternalProviderCapabilities,
    tasks: Vec<ExternalTask>,
    updates: std::sync::Arc<Mutex<Vec<(String, Vec<ExternalSyncField>)>>>,
    precondition_fails: bool,
}

impl UpdateFakeSyncClient {
    fn new(
        provider: ExternalProvider,
        update_fields: Vec<ExternalSyncField>,
        tasks: Vec<ExternalTask>,
    ) -> Self {
        Self {
            provider,
            capabilities: ExternalProviderCapabilities::with_update_fields(update_fields),
            tasks,
            updates: std::sync::Arc::new(Mutex::new(Vec::new())),
            precondition_fails: false,
        }
    }

    fn with_precondition_failure(mut self) -> Self {
        self.precondition_fails = true;
        self
    }
}

#[async_trait]
impl ExternalSyncClient for UpdateFakeSyncClient {
    fn provider(&self) -> ExternalProvider {
        self.provider
    }

    fn capabilities(&self) -> ExternalProviderCapabilities {
        self.capabilities.clone()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        Ok(self.tasks.clone())
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Ok(ExternalTaskRef::new(self.provider, item.id.clone()))
    }

    async fn update_task(
        &self,
        _item: &TaskBoardItem,
        reference: &ExternalTaskRef,
        update: ExternalTaskUpdate,
    ) -> Result<ExternalUpdateOutcome, CliError> {
        if self.precondition_fails && update.precondition_updated_at.is_some() {
            return Ok(ExternalUpdateOutcome::PreconditionFailed);
        }
        self.updates
            .lock()
            .expect("updates")
            .push((reference.external_id.clone(), update.changed_fields));
        Ok(ExternalUpdateOutcome::Applied {
            reference: reference.clone(),
            provider_revision: Some("provider-revision-2".into()),
        })
    }
}

fn linked_item(id: &str, title: &str, body: &str, status: TaskBoardStatus) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        body.to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = status;
    let mut reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Old title".to_string()),
        body: Some("Old body".to_string()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: None,
        updated_at: Some("2026-05-14T00:00:00Z".to_string()),
        synced_at: Some("2026-05-14T00:00:00Z".to_string()),
    });
    item.external_refs.push(reference);
    item
}

fn remote_task(
    external_id: &str,
    title: &str,
    body: &str,
    status: TaskBoardStatus,
) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, external_id),
        title: title.to_string(),
        body: body.to_string(),
        status,
        project_id: None,
        updated_at: Some("2026-05-14T01:00:00Z".to_string()),
    }
}
