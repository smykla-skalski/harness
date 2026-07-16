use crate::errors::CliError;
use crate::task_board::external::targeting::execution_repository_for_task;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncField, ExternalTask, ExternalTaskRef,
};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{ExternalRef, ExternalRefSyncState, TaskBoardItem, TaskBoardStatus};

use super::super::github::reconciled_external_status;
use super::conflicts::build_sync_conflicts;
use super::merge::{
    changed_fields, external_ref_matches, matching_ref, pull_conflict_fields, sync_state_from_task,
};
use super::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    OperationDraft, TaskBoardSyncStore, operation,
};

#[expect(
    clippy::cognitive_complexity,
    reason = "reconciliation keeps conflict policy, dry-run, and local CAS branches explicit"
)]
pub(super) async fn reconcile_existing_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: ExternalTask,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let conflict_fields = pull_conflict_fields(item, &task);
    let reports_conflicts = matches!(options.direction, ExternalSyncDirection::Both)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report);
    if reports_conflicts && !options.dry_run {
        let item_revision = board.item_revision(&item.id).await?;
        let conflicts = build_sync_conflicts(item, &task, &conflict_fields, item_revision);
        board
            .replace_open_sync_conflicts(
                &item.id,
                provider,
                &task.reference.external_id,
                &conflicts,
            )
            .await?;
    }
    if reports_conflicts && !conflict_fields.is_empty() {
        operations.push(operation(OperationDraft {
            provider,
            action: ExternalSyncAction::Conflict,
            board_item_id: Some(item.id.clone()),
            reference: task.reference,
            dry_run: options.dry_run,
            applied: false,
            changed_fields: conflict_fields,
            unsupported_fields: Vec::new(),
        }));
        return Ok(());
    }
    let prefer_remote = matches!(
        options.conflict_policy,
        ExternalSyncConflictPolicy::PreferRemote
    );
    let patch = reconciliation_patch(item, &task, prefer_remote);
    if !has_reconciliation_change(&patch) {
        supersede_resolved_conflicts(board, options, provider, item, &task, &conflict_fields)
            .await?;
        return Ok(());
    }
    let changed_fields = changed_fields(&patch);
    if options.dry_run {
        operations.push(operation(OperationDraft {
            provider,
            action: ExternalSyncAction::Pull,
            board_item_id: Some(item.id.clone()),
            reference: task.reference,
            dry_run: true,
            applied: false,
            changed_fields,
            unsupported_fields: Vec::new(),
        }));
        return Ok(());
    }
    if let Err(error) = board.update_item(item, patch).await
        && (error.code() != "WORKFLOW_CONCURRENT"
            || latest_item_still_needs_reconciliation(board, item, &task, prefer_remote).await?)
    {
        return Err(error);
    }
    supersede_resolved_conflicts(board, options, provider, item, &task, &conflict_fields).await?;
    if matches!(
        options.conflict_policy,
        ExternalSyncConflictPolicy::PreferLocal
    ) && !conflict_fields.is_empty()
        && changed_fields.is_empty()
    {
        return Ok(());
    }
    operations.push(operation(OperationDraft {
        provider,
        action: ExternalSyncAction::Pull,
        board_item_id: Some(item.id.clone()),
        reference: task.reference.clone(),
        dry_run: false,
        applied: true,
        changed_fields,
        unsupported_fields: Vec::new(),
    }));
    Ok(())
}

async fn supersede_resolved_conflicts(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: &ExternalTask,
    conflict_fields: &[ExternalSyncField],
) -> Result<(), CliError> {
    let resolved = match options.conflict_policy {
        ExternalSyncConflictPolicy::Report => false,
        ExternalSyncConflictPolicy::PreferRemote => true,
        ExternalSyncConflictPolicy::PreferLocal => conflict_fields.is_empty(),
    };
    if resolved && !options.dry_run {
        board
            .replace_open_sync_conflicts(&item.id, provider, &task.reference.external_id, &[])
            .await?;
    }
    Ok(())
}

async fn latest_item_still_needs_reconciliation(
    board: &dyn TaskBoardSyncStore,
    expected_item: &TaskBoardItem,
    task: &ExternalTask,
    prefer_remote: bool,
) -> Result<bool, CliError> {
    let latest = board
        .list_items(None)
        .await?
        .into_iter()
        .find(|item| item.id == expected_item.id);
    Ok(latest.as_ref().is_none_or(|item| {
        has_reconciliation_change(&reconciliation_patch(item, task, prefer_remote))
    }))
}

fn reconciliation_patch(
    item: &TaskBoardItem,
    task: &ExternalTask,
    prefer_remote: bool,
) -> TaskBoardItemPatch {
    let mut patch = TaskBoardItemPatch::default();
    let sync_state = matching_ref(item, &task.reference, task.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref());
    if item.title != task.title
        && should_apply_remote(
            sync_state.and_then(|state| state.title.as_ref()),
            &item.title,
            &task.title,
            prefer_remote,
            true,
        )
    {
        patch.title = Some(task.title.clone());
    }
    let shared_review_without_body = task.body.is_empty()
        && task
            .reference
            .url
            .as_deref()
            .is_some_and(|url| url.contains("/pull/"));
    if item.body != task.body
        && !shared_review_without_body
        && should_apply_remote(
            sync_state.and_then(|state| state.body.as_ref()),
            &item.body,
            &task.body,
            prefer_remote,
            true,
        )
    {
        patch.body = Some(task.body.clone());
    }
    let status = reconciled_status(item, task);
    if item.status != status {
        patch.status = Some(status);
    }
    if item.project_id != task.project_id
        && should_apply_remote(
            sync_state.map(|state| &state.project_id),
            &item.project_id,
            &task.project_id,
            prefer_remote,
            true,
        )
    {
        patch.project_id = task
            .project_id
            .clone()
            .map_or(OptionalFieldPatch::Clear, OptionalFieldPatch::Set);
    }
    if item.execution_repository.is_none()
        && let Some(repository) = execution_repository_for_task(task)
    {
        patch.execution_repository = OptionalFieldPatch::Set(repository);
    }
    if let Some(refs) = reconciled_external_refs(item, task) {
        patch.external_refs = Some(refs);
    }
    patch
}

fn reconciled_status(item: &TaskBoardItem, task: &ExternalTask) -> TaskBoardStatus {
    let last_synced_status = matching_ref(item, &task.reference, task.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref())
        .and_then(|state| state.status);
    reconciled_external_status(item.status, last_synced_status, task.status)
}

fn should_apply_remote<T: PartialEq>(
    base: Option<&T>,
    local: &T,
    remote: &T,
    prefer_remote: bool,
    apply_without_base: bool,
) -> bool {
    prefer_remote || local == remote || base.map_or(apply_without_base, |base| local == base)
}

fn has_reconciliation_change(patch: &TaskBoardItemPatch) -> bool {
    patch.title.is_some()
        || patch.body.is_some()
        || patch.status.is_some()
        || !matches!(patch.project_id, OptionalFieldPatch::Unchanged)
        || !matches!(patch.execution_repository, OptionalFieldPatch::Unchanged)
        || patch.external_refs.is_some()
}

fn reconciled_external_refs(item: &TaskBoardItem, task: &ExternalTask) -> Option<Vec<ExternalRef>> {
    let reference = &task.reference;
    let mut changed = false;
    let next_sync_state = sync_state_from_task(task);
    let refs = item
        .external_refs
        .iter()
        .map(|candidate| {
            if external_ref_matches(item, candidate, reference, task.project_id.as_deref())
                && reference_changed(candidate, reference, &next_sync_state)
            {
                changed = true;
                let mut next = reference.clone().into_core_ref();
                next.sync_state = Some(next_sync_state.clone());
                return next;
            }
            candidate.clone()
        })
        .collect();
    changed.then_some(refs)
}

fn reference_changed(
    current: &ExternalRef,
    next: &ExternalTaskRef,
    next_state: &ExternalRefSyncState,
) -> bool {
    current.provider != next.provider.into()
        || current.external_id != next.external_id
        || current.url != next.url
        || current.sync_state.as_ref().is_none_or(|current_state| {
            current_state.title != next_state.title
                || current_state.body != next_state.body
                || current_state.status != next_state.status
                || current_state.project_id != next_state.project_id
                || current_state.updated_at != next_state.updated_at
        })
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;

    use super::*;
    use crate::errors::CliErrorKind;
    use crate::task_board::TaskBoardSyncConflict;
    use crate::task_board::external::{
        ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
        ExternalProviderScopeState, ExternalSyncDirection,
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
            task,
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

        async fn item_revision(&self, _item_id: &str) -> Result<i64, CliError> {
            Ok(0)
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
        let mut reference =
            ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1").into_core_ref();
        reference.sync_state = Some(ExternalRefSyncState {
            title: Some("Old title".into()),
            body: Some("Body".into()),
            status: Some(TaskBoardStatus::Backlog),
            project_id: None,
            updated_at: Some("2026-07-15T10:00:00Z".into()),
            synced_at: Some("2026-07-15T10:00:00Z".into()),
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
        }
    }
}
