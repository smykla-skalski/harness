use crate::task_board::external::targeting::{
    execution_repository_for_task, provider_project_maps_to_board,
};
use crate::task_board::external::{ExternalTask, ExternalTaskRef};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{
    ExternalRef, ExternalRefSyncState, TaskBoardItem, TaskBoardItemKind, TaskBoardStatus,
};

use super::super::super::github::reconciled_external_status;
use super::super::merge::{
    external_ref_matches, matching_ref, reconcile_provider_labels, sync_state_from_task,
    task_signals_umbrella,
};

pub(in crate::task_board::external::sync) fn reconciliation_patch(
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

/// Labels the provider reported as of the last sync, from the matching
/// external ref's persisted snapshot, or empty if there is no prior sync.
fn last_synced_provider_labels(item: &TaskBoardItem, task: &ExternalTask) -> Vec<String> {
    matching_ref(item, &task.reference, task.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref())
        .map(|state| state.labels.clone())
        .unwrap_or_default()
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
        // One-directional: we promote to Umbrella whenever the provider
        // signals it, but we never demote an existing Umbrella back to
        // something else.
        patch.kind = Some(TaskBoardItemKind::Umbrella);
    }
    let last_synced_labels = last_synced_provider_labels(item, task);
    let merged_tags = reconcile_provider_labels(&item.tags, &task.labels, &last_synced_labels);
    if merged_tags != item.tags {
        patch.tags = Some(merged_tags);
    }
    // A self-reference (the remote body naming this same issue as its own
    // parent) is as unusable as a parent that hasn't imported yet, so it
    // takes the same "unresolvable" path below rather than being kept as a
    // valid target.
    let resolved_parent_item_id =
        resolved_parent_item_id.filter(|&parent_item_id| parent_item_id != item.id);
    match resolved_parent_item_id {
        Some(parent_item_id) if item.parent_item_id.as_deref() != Some(parent_item_id) => {
            patch.parent_item_id = OptionalFieldPatch::Set(parent_item_id.to_owned());
        }
        // The task still names a parent, just not one resolvable locally yet
        // (a re-parent to an issue not imported yet, or a self-reference,
        // rather than the absence of any parent at all): drop the stale
        // link instead of keeping whichever issue used to track it, and
        // defer to a later sync.
        None if task.parent_reference.is_some() && item.parent_item_id.is_some() => {
            patch.parent_item_id = OptionalFieldPatch::Clear;
        }
        _ => {}
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
                || current_state.labels != next_state.labels
        })
}
