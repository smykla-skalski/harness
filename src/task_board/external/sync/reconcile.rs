use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalTask, ExternalTaskRef,
};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{ExternalRef, ExternalRefSyncState, TaskBoardItem};

use super::merge::{
    changed_fields, external_ref_matches, pull_conflict_fields, sync_state_from_task,
};
use super::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    OperationDraft, TaskBoardSyncStore, operation,
};

pub(super) async fn reconcile_existing_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: ExternalTask,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let conflict_fields = pull_conflict_fields(item, &task);
    if matches!(options.direction, ExternalSyncDirection::Both)
        && !conflict_fields.is_empty()
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report)
    {
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
    if matches!(
        options.conflict_policy,
        ExternalSyncConflictPolicy::PreferLocal
    ) && !conflict_fields.is_empty()
    {
        return Ok(());
    }
    let patch = reconciliation_patch(item, &task);
    if !has_reconciliation_change(&patch) {
        return Ok(());
    }
    operations.push(operation(OperationDraft {
        provider,
        action: ExternalSyncAction::Pull,
        board_item_id: Some(item.id.clone()),
        reference: task.reference.clone(),
        dry_run: options.dry_run,
        applied: !options.dry_run,
        changed_fields: changed_fields(&patch),
        unsupported_fields: Vec::new(),
    }));
    if options.dry_run {
        return Ok(());
    }
    if let Err(error) = board.update_item(item, patch).await
        && (error.code() != "WORKFLOW_CONCURRENT"
            || latest_item_still_needs_reconciliation(board, item, &task).await?)
    {
        return Err(error);
    }
    Ok(())
}

async fn latest_item_still_needs_reconciliation(
    board: &dyn TaskBoardSyncStore,
    expected_item: &TaskBoardItem,
    task: &ExternalTask,
) -> Result<bool, CliError> {
    let latest = board
        .list_items(None)
        .await?
        .into_iter()
        .find(|item| item.id == expected_item.id);
    Ok(latest
        .as_ref()
        .is_none_or(|item| has_reconciliation_change(&reconciliation_patch(item, task))))
}

fn reconciliation_patch(item: &TaskBoardItem, task: &ExternalTask) -> TaskBoardItemPatch {
    let mut patch = TaskBoardItemPatch::default();
    if item.title != task.title {
        patch.title = Some(task.title.clone());
    }
    let shared_review_without_body = task.body.is_empty()
        && task
            .reference
            .url
            .as_deref()
            .is_some_and(|url| url.contains("/pull/"));
    if item.body != task.body && !shared_review_without_body {
        patch.body = Some(task.body.clone());
    }
    if item.status != task.status {
        patch.status = Some(task.status);
    }
    if item.project_id != task.project_id {
        patch.project_id = task
            .project_id
            .clone()
            .map_or(OptionalFieldPatch::Clear, OptionalFieldPatch::Set);
    }
    if let Some(refs) = reconciled_external_refs(item, task) {
        patch.external_refs = Some(refs);
    }
    patch
}

fn has_reconciliation_change(patch: &TaskBoardItemPatch) -> bool {
    patch.title.is_some()
        || patch.body.is_some()
        || patch.status.is_some()
        || !matches!(patch.project_id, OptionalFieldPatch::Unchanged)
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
