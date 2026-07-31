use async_trait::async_trait;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::super::merge::sync_state_from_task;
use super::*;
use crate::TaskBoardSyncConflict;
use crate::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    ExternalSyncDirection, ExternalTaskRef, TaskBoardExternalCreateStore,
    TaskBoardSyncItemSnapshot,
};
use crate::types::{ExternalRefSyncState, TaskBoardPriority, TaskBoardStatus};
use harness_kernel::errors::CliErrorKind;

#[tokio::test]
async fn prefer_remote_retries_against_a_concurrent_unrelated_edit() {
    let task = remote_task();
    let expected = locally_edited_item();
    let mut latest = expected.clone();
    latest.priority = TaskBoardPriority::High;
    latest.external_refs[0].sync_state = Some(sync_state_from_task(&task));
    let store = ConcurrentEditStore {
        latest: Mutex::new(latest),
        update_calls: AtomicUsize::new(0),
    };
    let mut operations = Vec::new();

    reconcile_existing_item(
        &store,
        ExternalSyncOptions {
            status: None,
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::PreferRemote,
            dry_run: false,
        },
        ExternalProvider::GitHub,
        &expected,
        0,
        task,
        None,
        &mut operations,
    )
    .await
    .expect("remote pull retries against the latest local item");

    let latest = store.latest.lock().expect("latest");
    assert_eq!(latest.title, "Remote edit");
    assert_eq!(latest.priority, TaskBoardPriority::High);
    assert_eq!(store.update_calls.load(Ordering::SeqCst), 2);
    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
}

struct ConcurrentEditStore {
    latest: Mutex<TaskBoardItem>,
    update_calls: AtomicUsize,
}

impl TaskBoardExternalCreateStore for ConcurrentEditStore {}

#[async_trait]
impl TaskBoardSyncStore for ConcurrentEditStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.latest.lock().expect("latest").clone()])
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.latest.lock().expect("latest").clone()])
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("reconciliation never creates an item")
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        if self.update_calls.fetch_add(1, Ordering::SeqCst) == 0 {
            return Err(CliErrorKind::concurrent_modification("concurrent test edit").into());
        }
        let mut latest = self.latest.lock().expect("latest");
        assert_eq!(expected_item, &*latest);
        apply_patch(&mut latest, patch);
        Ok(latest.clone())
    }

    async fn item_snapshot(&self, _item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        Ok(TaskBoardSyncItemSnapshot::new(
            self.latest.lock().expect("latest").clone(),
            1,
        ))
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

    async fn supersede_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _resolved_fields: &[ExternalSyncField],
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
    let mut reference = ExternalTaskRef::new(ExternalProvider::GitHub, "remote-1").into_core_ref();
    reference.sync_state = Some(ExternalRefSyncState {
        title: Some("Old title".into()),
        body: Some("Body".into()),
        status: Some(TaskBoardStatus::Inbox),
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
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "remote-1"),
        title: "Remote edit".into(),
        body: "Body".into(),
        status: TaskBoardStatus::Inbox,
        project_id: None,
        updated_at: Some("2026-07-15T10:05:00Z".into()),
        ..ExternalTask::default()
    }
}

#[test]
fn fast_refresh_preserves_local_and_last_synced_bodies() {
    let item = locally_edited_item();
    let mut task = remote_task();
    task.mark_body_unloaded();

    let patch = reconciliation_patch(&item, &task, true, None);

    assert!(patch.body.is_none());
    let refs = patch
        .external_refs
        .expect("provider revision still refreshes the reference");
    assert_eq!(
        refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.body.as_deref()),
        Some("Body")
    );
}

fn discovered_item() -> TaskBoardItem {
    TaskBoardItem::new(
        "task-1".into(),
        "Bump serde".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    )
}

fn discovered_pull_request_task() -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "remote-1"),
        pr_head_revision: Some("abc123".into()),
        pr_author: Some("renovate[bot]".into()),
        ..remote_task()
    }
}

#[test]
fn reconcile_backfills_missing_pull_request_head_and_author() {
    let item = discovered_item();
    assert!(item.workflow.pr_head_revision.is_none());

    let patch = reconciliation_patch(&item, &discovered_pull_request_task(), false, None);

    let workflow = patch
        .workflow
        .expect("head and author backfill onto the ticket");
    assert_eq!(workflow.pr_head_revision.as_deref(), Some("abc123"));
    assert_eq!(workflow.pr_author.as_deref(), Some("renovate[bot]"));
}

#[test]
fn reconcile_refreshes_an_advanced_pull_request_head() {
    let mut item = discovered_item();
    item.workflow.pr_head_revision = Some("frozen".into());
    item.workflow.pr_author = Some("renovate[bot]".into());

    let patch = reconciliation_patch(&item, &discovered_pull_request_task(), false, None);

    assert_eq!(
        patch
            .workflow
            .expect("advanced provider head updates the live ticket")
            .pr_head_revision
            .as_deref(),
        Some("abc123")
    );
}
