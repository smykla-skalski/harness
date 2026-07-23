use async_trait::async_trait;

use super::super::merge::sync_state_from_task;
use super::*;
use crate::errors::CliErrorKind;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    ExternalSyncDirection, TaskBoardSyncItemSnapshot,
};
use crate::task_board::{
    ExternalRefSyncState, ExternalTaskRef, TaskBoardStatus, TaskBoardSyncConflict,
};

#[tokio::test]
async fn prefer_remote_concurrent_edit_never_claims_unapplied_remote_intent() {
    let task = remote_task();
    let expected = locally_edited_item();
    let mut latest = expected.clone();
    latest.title = "Concurrent edit".into();
    latest.external_refs[0].sync_state = Some(sync_state_from_task(&task));
    let store = ConcurrentEditStore { latest };
    let mut operations = Vec::new();

    let error = reconcile_existing_item(
        &store,
        ExternalSyncOptions {
            status: None,
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::PreferRemote,
            dry_run: false,
        },
        ExternalProvider::Todoist,
        &expected,
        0,
        task,
        None,
        &mut operations,
    )
    .await
    .expect_err("concurrent edit still missing remote title must fail");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(operations.is_empty());
}

struct ConcurrentEditStore {
    latest: TaskBoardItem,
}

impl crate::task_board::TaskBoardExternalCreateStore for ConcurrentEditStore {}

#[async_trait]
impl TaskBoardSyncStore for ConcurrentEditStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.latest.clone()])
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.latest.clone()])
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("reconciliation never creates an item")
    }

    async fn update_item(
        &self,
        _expected_item: &TaskBoardItem,
        _patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        Err(CliErrorKind::concurrent_modification("concurrent test edit").into())
    }

    async fn item_snapshot(&self, _item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        Ok(TaskBoardSyncItemSnapshot::new(self.latest.clone(), 0))
    }

    async fn provider_scope_state(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        unreachable!("reconciliation test does not inspect provider scope state")
    }

    async fn begin_provider_scope_attempt(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
        _now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        unreachable!("reconciliation test does not begin provider attempts")
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        unreachable!("reconciliation test does not renew provider attempts")
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        unreachable!("reconciliation test does not complete provider attempts")
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        unreachable!("reconciliation test does not complete provider attempts")
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        Ok(())
    }
}

fn locally_edited_item() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "task-concurrent".into(),
        "Local edit".into(),
        "Body".into(),
        "2026-07-15T10:00:00Z".into(),
    );
    let mut reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Old title".into()),
        body: Some("Body".into()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: None,
        updated_at: Some("2026-07-15T10:00:00Z".into()),
        synced_at: Some("2026-07-15T10:00:00Z".into()),
        labels: Vec::new(),
    });
    item.external_refs = vec![reference];
    item
}

fn remote_task() -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1"),
        title: "Remote edit".into(),
        body: "Body".into(),
        status: TaskBoardStatus::Backlog,
        project_id: None,
        updated_at: Some("2026-07-15T10:05:00Z".into()),
        ..ExternalTask::default()
    }
}
