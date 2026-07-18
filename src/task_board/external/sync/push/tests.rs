use std::sync::Mutex;

use async_trait::async_trait;

use super::*;
use crate::errors::CliErrorKind;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::apply_patch;
use crate::task_board::{ExternalRefSyncState, TaskBoardSyncConflict};

mod revision_lifecycle_tests;

#[tokio::test]
async fn linked_push_is_not_applied_when_required_local_persistence_fails() {
    let item = linked_item();
    let mut listed_item = item.clone();
    listed_item.title = "Stale local edit".into();
    let store = FailingStore {
        item: item.clone(),
        listed_item,
        conflicts: Mutex::new(Vec::new()),
        updated_items: Mutex::new(Vec::new()),
        update_succeeds: false,
        conflict_error: None,
    };
    let client = UpdateClient;
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut operations = Vec::new();

    let error = persist_linked_update(
        &store,
        &client,
        &item,
        reference.clone(),
        AppliedRemoteUpdate {
            reference,
            provider_revision: ExternalRevisionUpdate::Set("provider-revision-2".into()),
        },
        vec![ExternalSyncField::Title],
        Vec::new(),
        &mut operations,
    )
    .await
    .expect_err("local persistence must fail");

    assert!(matches!(error, SyncClientError::Local(_)));
    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Push);
    assert!(!operations[0].applied);
    let conflicts = store.conflicts.lock().expect("conflicts");
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].local_value, serde_json::json!("Local edit"));
    assert_eq!(conflicts[0].item_revision, 2);
}

#[tokio::test]
async fn remote_update_evidence_survives_conflict_persistence_failure() {
    let item = linked_item();
    let store = failing_store(&item, false, Some("conflict persistence failed"));
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut operations = Vec::new();

    let error = persist_linked_update(
        &store,
        &UpdateClient,
        &item,
        reference.clone(),
        AppliedRemoteUpdate {
            reference,
            provider_revision: ExternalRevisionUpdate::Set("provider-revision-2".into()),
        },
        vec![ExternalSyncField::Title],
        Vec::new(),
        &mut operations,
    )
    .await
    .expect_err("local update and conflict persistence must fail");

    assert!(matches!(error, SyncClientError::Local(_)));
    assert_eq!(operations.len(), 1);
    assert!(!operations[0].applied);
}

#[tokio::test]
async fn applied_remote_update_evidence_survives_cleanup_failure() {
    let item = linked_item();
    let store = failing_store(&item, true, Some("conflict cleanup failed"));
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut operations = Vec::new();

    let error = persist_linked_update(
        &store,
        &UpdateClient,
        &item,
        reference.clone(),
        AppliedRemoteUpdate {
            reference,
            provider_revision: ExternalRevisionUpdate::Set("provider-revision-2".into()),
        },
        vec![ExternalSyncField::Title],
        Vec::new(),
        &mut operations,
    )
    .await
    .expect_err("conflict cleanup must fail");

    assert!(matches!(error, SyncClientError::Local(_)));
    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
}

#[tokio::test]
async fn missing_provider_revision_stays_unknown_in_conflict_evidence() {
    let item = linked_item();
    let store = failing_store(&item, false, None);
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut operations = Vec::new();

    persist_linked_update(
        &store,
        &UpdateClient,
        &item,
        reference.clone(),
        AppliedRemoteUpdate {
            reference,
            provider_revision: ExternalRevisionUpdate::Clear,
        },
        vec![ExternalSyncField::Title],
        Vec::new(),
        &mut operations,
    )
    .await
    .expect_err("local persistence must fail");

    let conflicts = store.conflicts.lock().expect("conflicts");
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].provider_revision, None);
}

#[tokio::test]
async fn successful_local_sync_preserves_known_revision_when_requested() {
    let item = linked_item();
    let store = failing_store(&item, true, None);
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut operations = Vec::new();

    let result = persist_linked_update(
        &store,
        &UpdateClient,
        &item,
        reference.clone(),
        AppliedRemoteUpdate {
            reference,
            provider_revision: ExternalRevisionUpdate::Preserve,
        },
        Vec::new(),
        Vec::new(),
        &mut operations,
    )
    .await;
    assert!(result.is_ok(), "local sync persistence");

    let updated_items = store.updated_items.lock().expect("updated items");
    let state = updated_items[0].external_refs[0]
        .sync_state
        .as_ref()
        .expect("updated sync state");
    assert_eq!(state.updated_at.as_deref(), Some("provider-revision-1"));
}

fn linked_item() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Local edit".into(),
        "Body".into(),
        "2026-07-16T10:00:00Z".into(),
    );
    let mut reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Base title".into()),
        body: Some("Body".into()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: None,
        updated_at: Some("provider-revision-1".into()),
        synced_at: Some("2026-07-16T10:00:00Z".into()),
    });
    item.external_refs = vec![reference];
    item
}

struct UpdateClient;

#[async_trait]
impl ExternalSyncClient for UpdateClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::Todoist
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        unreachable!("direct persistence test")
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("direct persistence test")
    }
}

struct FailingStore {
    item: TaskBoardItem,
    listed_item: TaskBoardItem,
    conflicts: Mutex<Vec<TaskBoardSyncConflict>>,
    updated_items: Mutex<Vec<TaskBoardItem>>,
    update_succeeds: bool,
    conflict_error: Option<&'static str>,
}

impl crate::task_board::TaskBoardExternalCreateStore for FailingStore {}

#[async_trait]
impl TaskBoardSyncStore for FailingStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.listed_item.clone()])
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.listed_item.clone()])
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("direct persistence test")
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        if self.update_succeeds {
            let mut updated = expected_item.clone();
            apply_patch(&mut updated, patch);
            self.updated_items
                .lock()
                .expect("updated items")
                .push(updated.clone());
            return Ok(updated);
        }
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
        unreachable!("direct persistence test")
    }

    async fn begin_provider_scope_attempt(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
        _now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        unreachable!("direct persistence test")
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        unreachable!("direct persistence test")
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        unreachable!("direct persistence test")
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        unreachable!("direct persistence test")
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        if let Some(message) = self.conflict_error {
            return Err(CliErrorKind::workflow_io(message).into());
        }
        *self.conflicts.lock().expect("conflicts") = conflicts.to_vec();
        Ok(())
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

fn failing_store(
    item: &TaskBoardItem,
    update_succeeds: bool,
    conflict_error: Option<&'static str>,
) -> FailingStore {
    FailingStore {
        item: item.clone(),
        listed_item: item.clone(),
        conflicts: Mutex::new(Vec::new()),
        updated_items: Mutex::new(Vec::new()),
        update_succeeds,
        conflict_error,
    }
}
