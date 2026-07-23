use std::sync::Mutex;

use async_trait::async_trait;

use super::*;
use crate::task_board::TaskBoardSyncConflict;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::TaskBoardStatus;

fn item(id: &str) -> TaskBoardItem {
    TaskBoardItem::new(id.into(), "Title".into(), String::new(), "2026-07-23T00:00:00Z".into())
}

fn task(external_id: &str) -> ExternalTask {
    ExternalTask {
        reference: crate::task_board::external::ExternalTaskRef::new(
            ExternalProvider::GitHub,
            external_id,
        ),
        title: "Title".into(),
        ..Default::default()
    }
}

#[derive(Default)]
struct FakeStore {
    hide_result: Mutex<Option<Option<TaskBoardItem>>>,
    restore_result: Mutex<Option<Option<TaskBoardItem>>>,
    restore_seen: Mutex<Option<TaskBoardItem>>,
}

impl crate::task_board::TaskBoardExternalCreateStore for FakeStore {}

#[async_trait]
impl TaskBoardSyncStore for FakeStore {
    async fn list_items(&self, _status: Option<TaskBoardStatus>) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(Vec::new())
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(Vec::new())
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("test does not create")
    }

    async fn update_item(
        &self,
        _expected_item: &TaskBoardItem,
        _patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        unreachable!("test does not update")
    }

    async fn item_snapshot(&self, _item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        unreachable!("test does not snapshot")
    }

    async fn hide_for_provider_exclusion(
        &self,
        _item_id: &str,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        Ok(self
            .hide_result
            .lock()
            .expect("lock")
            .take()
            .expect("hide result configured"))
    }

    async fn restore_from_provider_exclusion(
        &self,
        revived: TaskBoardItem,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        *self.restore_seen.lock().expect("lock") = Some(revived);
        Ok(self
            .restore_result
            .lock()
            .expect("lock")
            .take()
            .expect("restore result configured"))
    }

    async fn provider_scope_state(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        unreachable!("test does not inspect provider scope state")
    }

    async fn begin_provider_scope_attempt(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
        _now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        unreachable!("test does not begin provider attempts")
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        unreachable!("test does not renew provider attempts")
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        unreachable!("test does not complete provider attempts")
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        unreachable!("test does not fail provider attempts")
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        unreachable!("test does not record conflicts")
    }
}

#[tokio::test]
async fn hide_reports_dry_run_without_calling_the_store() {
    let store = FakeStore::default();
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        ExternalSyncOptions {
            dry_run: true,
            ..Default::default()
        },
        ExternalProvider::GitHub,
        &item("item-1"),
        task("42"),
        &mut operations,
    )
    .await
    .expect("dry-run hide succeeds");

    assert_eq!(operations.len(), 1);
    assert!(!operations[0].applied);
    assert!(operations[0].dry_run);
}

#[tokio::test]
async fn hide_records_an_applied_operation_when_the_store_hides_it() {
    let store = FakeStore::default();
    *store.hide_result.lock().expect("lock") = Some(Some(item("item-1")));
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        ExternalSyncOptions {
            dry_run: false,
            ..Default::default()
        },
        ExternalProvider::GitHub,
        &item("item-1"),
        task("42"),
        &mut operations,
    )
    .await
    .expect("hide succeeds");

    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
    assert!(!operations[0].dry_run);
}

#[tokio::test]
async fn hide_records_nothing_when_the_store_declines_to_hide() {
    let store = FakeStore::default();
    *store.hide_result.lock().expect("lock") = Some(None);
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        ExternalSyncOptions {
            dry_run: false,
            ..Default::default()
        },
        ExternalProvider::GitHub,
        &item("item-1"),
        task("42"),
        &mut operations,
    )
    .await
    .expect("hide call succeeds");

    assert!(
        operations.is_empty(),
        "an ineligible item must not report an operation"
    );
}

#[tokio::test]
async fn restore_builds_the_revived_item_from_the_current_provider_task() {
    let store = FakeStore::default();
    *store.restore_result.lock().expect("lock") = Some(Some(item("restored")));
    let task = task("42");

    let restored = try_restore_provider_exclusion_tombstone(&store, &task)
        .await
        .expect("restore call succeeds");

    assert!(restored.is_some());
    let seen = store
        .restore_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("restore was attempted");
    assert_eq!(seen.id, create_item_from_external(&task).id);
    assert_eq!(seen.title, task.title);
}
