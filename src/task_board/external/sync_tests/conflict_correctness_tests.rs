use std::sync::Mutex;

use async_trait::async_trait;
use tempfile::tempdir;

use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliErrorKind;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{ExternalRefProvider, TaskBoardConflictState, TaskBoardSyncConflict};

#[tokio::test]
async fn push_precondition_failure_persists_three_way_conflict() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = linked_item(
        "task-precondition",
        "Local edit",
        "Old body",
        TaskBoardStatus::Todo,
    );
    db.create_task_board_item(item).await.expect("create item");
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        Vec::new(),
    )
    .with_precondition_failure(remote_task(
        "remote-1",
        "Concurrent remote edit",
        "Old body",
        TaskBoardStatus::Backlog,
    ));
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(&db, push_options(), &clients)
        .await
        .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Conflict);
    let conflicts = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].field, "title");
    assert_eq!(conflicts[0].base_value, serde_json::json!("Old title"));
    assert_eq!(conflicts[0].local_value, serde_json::json!("Local edit"));
    assert_eq!(
        conflicts[0].remote_value,
        serde_json::json!("Concurrent remote edit")
    );
    assert_eq!(
        conflicts[0].provider_revision.as_deref(),
        Some("2026-05-14T01:00:00Z")
    );
}

#[tokio::test]
async fn prefer_remote_supersedes_existing_open_conflict() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = linked_item(
        "task-prefer-remote",
        "Local edit",
        "Old body",
        TaskBoardStatus::Todo,
    );
    db.create_task_board_item(item).await.expect("create item");
    record_open_title_conflict(&db, "task-prefer-remote").await;
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
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    sync_external_tasks(
        &db,
        both_options(ExternalSyncConflictPolicy::PreferRemote),
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(
        db.task_board_item("task-prefer-remote")
            .await
            .expect("item")
            .title,
        "Remote edit"
    );
    assert!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("open conflicts")
            .is_empty()
    );
}

#[tokio::test]
async fn pull_report_supersedes_only_converged_known_conflict_fields() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = linked_item(
        "task-pull-report",
        "Local edit",
        "Old body",
        TaskBoardStatus::Todo,
    );
    db.create_task_board_item(item).await.expect("create item");
    record_open_title_and_future_conflicts(&db, "task-pull-report").await;
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
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    sync_external_tasks(&db, pull_report_options(), &clients)
        .await
        .expect("pull report sync");

    assert_eq!(
        db.task_board_item("task-pull-report")
            .await
            .expect("item")
            .title,
        "Remote edit"
    );
    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].field, "future_field");
}

#[tokio::test]
async fn prefer_local_supersedes_conflict_after_remote_and_local_state_converge() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let item = linked_item(
        "task-prefer-local",
        "Local edit",
        "Old body",
        TaskBoardStatus::Todo,
    );
    db.create_task_board_item(item).await.expect("create item");
    record_open_title_conflict(&db, "task-prefer-local").await;
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        vec![remote_task(
            "remote-1",
            "Remote edit",
            "Remote body",
            TaskBoardStatus::Backlog,
        )],
    );
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &db,
        both_options(ExternalSyncConflictPolicy::PreferLocal),
        &clients,
    )
    .await
    .expect("sync external tasks");

    let item = db.task_board_item("task-prefer-local").await.expect("item");
    assert_eq!(item.title, "Local edit");
    assert_eq!(item.body, "Remote body");
    let pull = operations
        .iter()
        .find(|operation| operation.action == ExternalSyncAction::Pull)
        .expect("non-conflicting remote change is recorded");
    assert!(pull.applied);
    assert_eq!(pull.changed_fields, vec![ExternalSyncField::Body]);
    assert_eq!(
        *updates.lock().expect("updates"),
        vec![("remote-1".to_string(), vec![ExternalSyncField::Title])]
    );
    assert!(
        db.open_task_board_sync_conflicts()
            .await
            .expect("open conflicts")
            .is_empty()
    );
}

#[tokio::test]
async fn remote_update_with_failed_local_persistence_records_conflict_evidence() {
    let item = linked_item(
        "task-local-cas",
        "Local edit",
        "Old body",
        TaskBoardStatus::Todo,
    );
    let store = FailingPersistenceStore::new(item);
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Title],
        Vec::new(),
    );
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let error = sync_external_tasks(&store, push_options(), &clients)
        .await
        .expect_err("local persistence must fail");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(
        *updates.lock().expect("updates"),
        vec![("remote-1".to_string(), vec![ExternalSyncField::Title])]
    );
    let conflicts = store.conflicts.lock().expect("conflicts");
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].field, "title");
    assert_eq!(conflicts[0].base_value, serde_json::json!("Old title"));
    assert_eq!(conflicts[0].local_value, serde_json::json!("Local edit"));
    assert_eq!(conflicts[0].remote_value, serde_json::json!("Local edit"));
    assert_eq!(
        conflicts[0].provider_revision.as_deref(),
        Some("provider-revision-2")
    );
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

fn both_options(conflict_policy: ExternalSyncConflictPolicy) -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(ExternalProvider::Todoist),
        direction: ExternalSyncDirection::Both,
        conflict_policy,
        dry_run: false,
        status: None,
    }
}

fn pull_report_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(ExternalProvider::Todoist),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
        status: None,
    }
}

async fn record_open_title_conflict(db: &AsyncDaemonDb, item_id: &str) {
    record_open_conflicts(db, item_id, &["title"]).await;
}

async fn record_open_title_and_future_conflicts(db: &AsyncDaemonDb, item_id: &str) {
    record_open_conflicts(db, item_id, &["title", "future_field"]).await;
}

async fn record_open_conflicts(db: &AsyncDaemonDb, item_id: &str, fields: &[&str]) {
    let revision = db
        .task_board_item_snapshot(item_id)
        .await
        .expect("item snapshot")
        .item_revision;
    let conflicts = fields
        .iter()
        .map(|field| open_conflict(item_id, field, revision))
        .collect::<Vec<_>>();
    db.replace_open_task_board_sync_conflicts(
        item_id,
        ExternalProvider::Todoist,
        "remote-1",
        revision,
        &conflicts,
    )
    .await
    .expect("record conflict");
}

fn open_conflict(item_id: &str, field: &str, revision: i64) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: format!("conflict-{item_id}-{field}"),
        item_id: item_id.into(),
        provider: ExternalRefProvider::Todoist,
        external_ref: "remote-1".into(),
        field: field.into(),
        base_value: serde_json::json!("Old value"),
        local_value: serde_json::json!("Local value"),
        remote_value: serde_json::json!("Remote value"),
        item_revision: revision,
        provider_revision: Some("2026-05-14T01:00:00Z".into()),
        state: TaskBoardConflictState::Open,
    }
}

struct FailingPersistenceStore {
    item: TaskBoardItem,
    conflicts: Mutex<Vec<TaskBoardSyncConflict>>,
}

impl FailingPersistenceStore {
    fn new(item: TaskBoardItem) -> Self {
        Self {
            item,
            conflicts: Mutex::new(Vec::new()),
        }
    }
}

impl crate::task_board::TaskBoardExternalCreateStore for FailingPersistenceStore {}

#[async_trait]
impl TaskBoardSyncStore for FailingPersistenceStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.item.clone()])
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.item.clone()])
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("push-only linked task")
    }

    async fn update_item(
        &self,
        _expected_item: &TaskBoardItem,
        _patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        Err(CliErrorKind::concurrent_modification("local CAS failed").into())
    }

    async fn item_snapshot(&self, _item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        Ok(TaskBoardSyncItemSnapshot::new(self.item.clone(), 2))
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
                format!("test:{provider}:{scope_id}"),
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
        Ok(ExternalProviderScopeState::default())
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        *self.conflicts.lock().expect("conflicts") = conflicts.to_vec();
        Ok(())
    }
}
