use std::sync::Mutex;

use async_trait::async_trait;

use super::*;
use crate::errors::CliErrorKind;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
};
use crate::task_board::{ExternalRefSyncState, TaskBoardSyncConflict};

#[tokio::test]
async fn linked_push_is_not_applied_when_required_local_persistence_fails() {
    let item = linked_item();
    let store = FailingStore {
        item: item.clone(),
        conflicts: Mutex::new(Vec::new()),
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
            provider_revision: Some("provider-revision-2".into()),
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
    assert_eq!(store.conflicts.lock().expect("conflicts").len(), 1);
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
    conflicts: Mutex<Vec<TaskBoardSyncConflict>>,
}

#[async_trait]
impl TaskBoardSyncStore for FailingStore {
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
        unreachable!("direct persistence test")
    }

    async fn update_item(
        &self,
        _expected_item: &TaskBoardItem,
        _patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        Err(CliErrorKind::concurrent_modification("local CAS failed").into())
    }

    async fn item_revision(&self, _item_id: &str) -> Result<i64, CliError> {
        Ok(2)
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
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        *self.conflicts.lock().expect("conflicts") = conflicts.to_vec();
        Ok(())
    }
}
