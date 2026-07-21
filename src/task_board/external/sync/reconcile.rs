use crate::errors::CliError;
use crate::task_board::external::targeting::{
    execution_repository_for_task, provider_project_maps_to_board,
};
use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncField, ExternalTask, ExternalTaskRef,
};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{
    ExternalRef, ExternalRefSyncState, TaskBoardItem, TaskBoardItemKind, TaskBoardStatus,
};

use super::super::github::reconciled_external_status;
use super::conflicts::build_sync_conflicts;
use super::merge::{
    changed_fields, external_ref_matches, matching_ref, merge_external_labels,
    pull_conflict_fields, pull_resolution_fields, sync_state_from_task, task_signals_umbrella,
};
use super::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    OperationDraft, TaskBoardSyncStore, canonical_external_status, operation,
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
    resolved_parent_item_id: Option<&str>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let reports_conflicts = matches!(options.direction, ExternalSyncDirection::Both)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report);
    let snapshot = if reports_conflicts && !options.dry_run {
        Some(board.item_snapshot(&item.id).await?)
    } else {
        None
    };
    let item = snapshot.as_ref().map_or(item, |snapshot| &snapshot.item);
    let conflict_fields = pull_conflict_fields(item, &task);
    if let Some(snapshot) = &snapshot {
        let conflicts = build_sync_conflicts(item, &task, &conflict_fields, snapshot.item_revision);
        board
            .replace_open_sync_conflicts(
                &item.id,
                provider,
                &task.reference.external_id,
                snapshot.item_revision,
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
    ) || matches!(options.direction, ExternalSyncDirection::Pull)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report);
    let patch = reconciliation_patch(item, &task, prefer_remote, resolved_parent_item_id);
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
    let applied = apply_reconciliation(
        board,
        item,
        &task,
        prefer_remote,
        resolved_parent_item_id,
        patch,
    )
    .await?;
    let records_applied_operation = applied
        && !(matches!(
            options.conflict_policy,
            ExternalSyncConflictPolicy::PreferLocal
        ) && !conflict_fields.is_empty()
            && changed_fields.is_empty());
    if records_applied_operation {
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
    }
    supersede_resolved_conflicts(board, options, provider, item, &task, &conflict_fields).await?;
    Ok(())
}

async fn apply_reconciliation(
    board: &dyn TaskBoardSyncStore,
    item: &TaskBoardItem,
    task: &ExternalTask,
    prefer_remote: bool,
    resolved_parent_item_id: Option<&str>,
    patch: TaskBoardItemPatch,
) -> Result<bool, CliError> {
    match board.update_item(item, patch).await {
        Ok(_) => Ok(true),
        Err(error) if error.code() != "WORKFLOW_CONCURRENT" => Err(error),
        Err(error) => {
            if latest_item_still_needs_reconciliation(
                board,
                item,
                task,
                prefer_remote,
                resolved_parent_item_id,
            )
            .await?
            {
                return Err(error);
            }
            Ok(false)
        }
    }
}

async fn supersede_resolved_conflicts(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: &ExternalTask,
    conflict_fields: &[ExternalSyncField],
) -> Result<(), CliError> {
    if options.dry_run || !conflicts_are_resolved(options, conflict_fields) {
        return Ok(());
    }
    let snapshot = board.item_snapshot(&item.id).await?;
    let resolved_fields = converged_pull_fields(&snapshot.item, task);
    board
        .supersede_open_sync_conflicts(
            &item.id,
            provider,
            &task.reference.external_id,
            snapshot.item_revision,
            &resolved_fields,
        )
        .await
}

fn conflicts_are_resolved(
    options: ExternalSyncOptions,
    conflict_fields: &[ExternalSyncField],
) -> bool {
    match options.conflict_policy {
        ExternalSyncConflictPolicy::Report => {
            matches!(options.direction, ExternalSyncDirection::Pull)
        }
        ExternalSyncConflictPolicy::PreferRemote => true,
        ExternalSyncConflictPolicy::PreferLocal => conflict_fields.is_empty(),
    }
}

fn converged_pull_fields(item: &TaskBoardItem, task: &ExternalTask) -> Vec<ExternalSyncField> {
    pull_resolution_fields(task)
        .into_iter()
        .filter(|field| match field {
            ExternalSyncField::Title => item.title == task.title,
            ExternalSyncField::Body => item.body == task.body,
            ExternalSyncField::Status => {
                canonical_external_status(item.status) == canonical_external_status(task.status)
            }
            ExternalSyncField::Project => item.project_id == task.project_id,
            ExternalSyncField::Url => {
                matching_ref(item, &task.reference, task.project_id.as_deref())
                    .is_some_and(|reference| reference.url == task.reference.url)
            }
        })
        .collect()
}

async fn latest_item_still_needs_reconciliation(
    board: &dyn TaskBoardSyncStore,
    expected_item: &TaskBoardItem,
    task: &ExternalTask,
    prefer_remote: bool,
    resolved_parent_item_id: Option<&str>,
) -> Result<bool, CliError> {
    let latest = board
        .list_items(None)
        .await?
        .into_iter()
        .find(|item| item.id == expected_item.id);
    Ok(latest.as_ref().is_none_or(|item| {
        has_reconciliation_change(&reconciliation_patch(
            item,
            task,
            prefer_remote,
            resolved_parent_item_id,
        ))
    }))
}

fn reconciliation_patch(
    item: &TaskBoardItem,
    task: &ExternalTask,
    prefer_remote: bool,
    resolved_parent_item_id: Option<&str>,
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
    if provider_project_maps_to_board(task.reference.provider)
        && item.project_id != task.project_id
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
    apply_hierarchy_patch(&mut patch, item, task, resolved_parent_item_id);
    patch
}

/// Reconciles tags, kind, and parent linkage. Split out from
/// `reconciliation_patch` to keep that function's branch count under the
/// cognitive-complexity gate.
fn apply_hierarchy_patch(
    patch: &mut TaskBoardItemPatch,
    item: &TaskBoardItem,
    task: &ExternalTask,
    resolved_parent_item_id: Option<&str>,
) {
    if task_signals_umbrella(task) && item.kind != TaskBoardItemKind::Umbrella {
        // One-directional: recognizing an umbrella is automatic, but a human
        // may have deliberately picked some other kind, so this never demotes.
        patch.kind = Some(TaskBoardItemKind::Umbrella);
    }
    let merged_tags = merge_external_labels(&item.tags, &task.labels);
    if merged_tags != item.tags {
        patch.tags = Some(merged_tags);
    }
    if let Some(parent_item_id) = resolved_parent_item_id
        && parent_item_id != item.id
        && item.parent_item_id.as_deref() != Some(parent_item_id)
    {
        patch.parent_item_id = OptionalFieldPatch::Set(parent_item_id.to_owned());
    }
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
        || patch.kind.is_some()
        || patch.tags.is_some()
        || !matches!(patch.parent_item_id, OptionalFieldPatch::Unchanged)
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
mod tests;
