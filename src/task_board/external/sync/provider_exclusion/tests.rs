use std::sync::Mutex;

use async_trait::async_trait;

use super::*;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::types::{ExternalRefProvider, TaskBoardStatus};
use crate::task_board::{ExternalTaskRef, TaskBoardSyncConflict};

fn item(id: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-23T00:00:00Z".into(),
    )
}

fn item_with_ref(id: &str) -> TaskBoardItem {
    let mut value = item(id);
    value.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    value
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

fn excluded_task(external_id: &str) -> ExternalTask {
    let mut value = task(external_id);
    value.labels = vec!["duplicate".into()];
    value
}

#[derive(Default)]
struct FakeStore {
    hide_result: Mutex<Option<Option<TaskBoardItem>>>,
    hide_seen: Mutex<Option<(TaskBoardItemPatch, Option<Vec<TaskBoardSyncConflict>>)>>,
    restore_result: Mutex<Option<ProviderExclusionRestoreOutcome>>,
    restore_seen: Mutex<
        Option<(
            TaskBoardSyncItemSnapshot,
            TaskBoardItemPatch,
            Option<Vec<TaskBoardSyncConflict>>,
        )>,
    >,
}

impl crate::task_board::TaskBoardExternalCreateStore for FakeStore {}

#[async_trait]
impl TaskBoardSyncStore for FakeStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
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
        _expected_revision: i64,
        patch: TaskBoardItemPatch,
        _context: ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        *self.hide_seen.lock().expect("lock") = Some((patch, conflicts));
        Ok(self
            .hide_result
            .lock()
            .expect("lock")
            .take()
            .expect("hide result configured"))
    }

    async fn restore_from_provider_exclusion(
        &self,
        expected: TaskBoardSyncItemSnapshot,
        patch: TaskBoardItemPatch,
        _context: ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<ProviderExclusionRestoreOutcome, CliError> {
        *self.restore_seen.lock().expect("lock") = Some((expected, patch, conflicts));
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

fn pull_options(dry_run: bool) -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: None,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::PreferRemote,
        dry_run,
    }
}

fn todoist_pull_options(dry_run: bool) -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(ExternalProvider::Todoist),
        ..pull_options(dry_run)
    }
}

fn both_report_options(dry_run: bool) -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: None,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Both,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run,
    }
}

#[tokio::test]
async fn hide_reports_dry_run_without_calling_the_store() {
    let store = FakeStore::default();
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        pull_options(true),
        ExternalProvider::GitHub,
        &item_with_ref("item-1"),
        0,
        excluded_task("42"),
        "duplicate".into(),
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
    let matched = item_with_ref("item-1");

    hide_existing_item_for_exclusion(
        &store,
        pull_options(false),
        ExternalProvider::GitHub,
        &matched,
        3,
        excluded_task("42"),
        "duplicate".into(),
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
    let matched = item_with_ref("item-1");

    hide_existing_item_for_exclusion(
        &store,
        pull_options(false),
        ExternalProvider::GitHub,
        &matched,
        3,
        excluded_task("42"),
        "duplicate".into(),
        &mut operations,
    )
    .await
    .expect("hide call succeeds");

    assert!(
        operations.is_empty(),
        "an ineligible item must not report an operation"
    );
}

#[path = "restore_tests.rs"]
mod restore_tests;

#[tokio::test]
async fn hide_reports_both_a_conflict_and_an_applied_pull_operation_when_fields_disagree() {
    let store = FakeStore::default();
    *store.hide_result.lock().expect("lock") = Some(Some(item("item-1")));
    let mut matched = item_with_ref("item-1");
    matched.title = "Stored title".into();
    let mut incoming = excluded_task("42");
    incoming.title = "Provider title".into();
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        both_report_options(false),
        ExternalProvider::GitHub,
        &matched,
        3,
        incoming,
        "duplicate".into(),
        &mut operations,
    )
    .await
    .expect("hide succeeds");

    assert_eq!(
        operations.len(),
        2,
        "a hide that also disagrees on fields must report both the conflict and the applied hide"
    );
    assert!(matches!(operations[0].action, ExternalSyncAction::Conflict));
    assert!(!operations[0].applied);
    assert!(matches!(operations[1].action, ExternalSyncAction::Pull));
    assert!(operations[1].applied);

    let (_patch, conflicts) = store
        .hide_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("hide was attempted");
    let conflicts = conflicts.expect("Both+Report must pass Some conflicts");
    assert!(!conflicts.is_empty());
}

#[tokio::test]
async fn hide_preserves_local_title_and_body_when_no_baseline_conflicts_with_them() {
    let store = FakeStore::default();
    *store.hide_result.lock().expect("lock") = Some(Some(item("item-1")));
    let mut matched = item_with_ref("item-1");
    matched.title = "Stored title".into();
    matched.body = "Stored body".into();
    let mut incoming = excluded_task("42");
    incoming.title = "Provider title".into();
    incoming.body = "Provider body".into();
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        both_report_options(false),
        ExternalProvider::GitHub,
        &matched,
        3,
        incoming,
        "duplicate".into(),
        &mut operations,
    )
    .await
    .expect("hide succeeds");

    let (patch, _conflicts) = store
        .hide_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("hide was attempted");
    assert_eq!(
        patch.title, None,
        "a reported title conflict must not overwrite the stored title, even without a sync baseline"
    );
    assert_eq!(
        patch.body, None,
        "a reported body conflict must not overwrite the stored body, even without a sync baseline"
    );
}

#[tokio::test]
async fn hide_preserves_conflict_baselines_for_a_later_restore() {
    let store = FakeStore::default();
    *store.hide_result.lock().expect("lock") = Some(Some(item("item-1")));
    let mut matched = item_with_ref("item-1");
    matched.title = "Local title".into();
    matched.body = "Local body".into();
    let mut excluded = excluded_task("42");
    excluded.title = "Provider title".into();
    excluded.body = "Provider body".into();
    let mut hide_operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        both_report_options(false),
        ExternalProvider::GitHub,
        &matched,
        3,
        excluded,
        "duplicate".into(),
        &mut hide_operations,
    )
    .await
    .expect("hide succeeds");

    let (hide_patch, hide_conflicts) = store
        .hide_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("hide was attempted");
    assert_eq!(hide_patch.title, None);
    assert_eq!(hide_patch.body, None);
    assert!(
        hide_conflicts
            .as_ref()
            .is_some_and(|conflicts| !conflicts.is_empty())
    );
    let state = hide_patch.external_refs.as_ref().expect("ref patch")[0]
        .sync_state
        .as_ref()
        .expect("sync state");
    assert_eq!(state.title, None);
    assert_eq!(state.body, None);
    assert_eq!(state.labels, vec!["duplicate".to_string()]);

    let mut tombstone = matched;
    apply_patch(&mut tombstone, hide_patch);
    tombstone.deleted_at = Some("2026-07-23T00:05:00Z".into());
    tombstone.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    let index = ProviderItemIndex::build(vec![TaskBoardSyncItemSnapshot::new(tombstone, 4)]);
    *store.restore_result.lock().expect("lock") =
        Some(ProviderExclusionRestoreOutcome::ConflictPublished);
    let mut restored_task = task("42");
    restored_task.title = "Provider title".into();
    restored_task.body = "Provider body".into();
    restored_task.labels = vec!["kind/bug".into()];
    let mut restore_operations = Vec::new();

    try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        both_report_options(false),
        ExternalProvider::GitHub,
        &restored_task,
        None,
        &mut restore_operations,
    )
    .await
    .expect("restore conflict succeeds");

    let (_, _, restore_conflicts) = store
        .restore_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("restore was attempted");
    let fields = restore_conflicts
        .expect("Both+Report conflict list")
        .into_iter()
        .map(|conflict| conflict.field)
        .collect::<Vec<_>>();
    assert_eq!(fields, vec!["title".to_string(), "body".to_string()]);
}

#[tokio::test]
async fn hide_reports_only_fields_the_pull_applied() {
    let store = FakeStore::default();
    *store.hide_result.lock().expect("lock") = Some(Some(item("item-1")));
    let mut matched = item_with_ref("item-1");
    matched.external_refs[0].provider = ExternalRefProvider::Todoist;
    matched.title = "Local title".into();
    matched.body = "Local body".into();
    matched.project_id = Some("local/project".into());
    let mut incoming = excluded_task("42");
    incoming.reference = ExternalTaskRef::new(ExternalProvider::Todoist, "42");
    incoming.title = "Provider title".into();
    incoming.body = "Provider body".into();
    incoming.project_id = Some("provider/project".into());
    let mut operations = Vec::new();

    hide_existing_item_for_exclusion(
        &store,
        todoist_pull_options(false),
        ExternalProvider::Todoist,
        &matched,
        3,
        incoming,
        "duplicate".into(),
        &mut operations,
    )
    .await
    .expect("hide succeeds");

    assert_eq!(operations.len(), 1);
    assert_eq!(
        operations[0].changed_fields,
        vec![
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Status,
            ExternalSyncField::Project,
        ]
    );
}
