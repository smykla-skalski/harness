use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncField, ExternalTask,
};
use crate::task_board::matched_exclusion_label;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch, apply_patch};
use crate::task_board::types::TaskBoardItem;

use super::conflicts::build_sync_conflicts;
use super::merge::{changed_fields, matching_ref, pull_conflict_fields, pull_resolution_fields};
use super::provider_exclusion::hide_existing_item_for_exclusion;
use super::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    OperationDraft, TaskBoardSyncStore, canonical_external_status, operation,
};

mod patch;
pub(super) use patch::reconciliation_patch;

#[expect(
    clippy::cognitive_complexity,
    clippy::too_many_arguments,
    reason = "reconciliation keeps conflict policy, CAS state, hierarchy, and operation output explicit"
)]
pub(super) async fn reconcile_existing_item(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    expected_revision: i64,
    task: ExternalTask,
    resolved_parent_item_id: Option<&str>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if let Some(matched_label) = matched_exclusion_label(&task.labels) {
        return hide_existing_item_for_exclusion(
            board,
            options,
            provider,
            item,
            expected_revision,
            task,
            matched_label,
            operations,
        )
        .await;
    }
    let conflict_fields = pull_conflict_fields(item, &task);
    if report_reconcile_conflicts_if_any(
        board,
        options,
        provider,
        item,
        &task,
        expected_revision,
        &conflict_fields,
        operations,
    )
    .await?
    {
        return Ok(());
    }
    let prefer_remote = matches!(
        options.conflict_policy,
        ExternalSyncConflictPolicy::PreferRemote
    ) || matches!(options.direction, ExternalSyncDirection::Pull)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report);
    let patch = reconciliation_patch(item, &task, prefer_remote, resolved_parent_item_id);
    if !has_reconciliation_change(&patch) {
        supersede_resolved_conflicts(
            board,
            options,
            provider,
            item,
            &task,
            &conflict_fields,
            expected_revision,
        )
        .await?;
        return Ok(());
    }
    let changed_fields = changed_fields(&patch);
    let hierarchy_changed = hierarchy_fields_changed(&patch);
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
    let patch_for_convergence = patch.clone();
    let applied_revision = apply_reconciliation(board, item, expected_revision, patch).await?;
    record_reconciliation_write(
        board,
        options,
        provider,
        item,
        &task,
        &conflict_fields,
        changed_fields,
        hierarchy_changed,
        patch_for_convergence,
        applied_revision,
        operations,
    )
    .await
}

#[expect(
    clippy::too_many_arguments,
    reason = "gate needs board/policy/item/task/operations together"
)]
async fn report_reconcile_conflicts_if_any(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: &ExternalTask,
    expected_revision: i64,
    conflict_fields: &[ExternalSyncField],
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<bool, CliError> {
    let reports_conflicts = matches!(options.direction, ExternalSyncDirection::Both)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report);
    if reports_conflicts && !options.dry_run {
        let conflicts = build_sync_conflicts(item, task, conflict_fields, expected_revision);
        board
            .replace_open_sync_conflicts(
                &item.id,
                provider,
                &task.reference.external_id,
                expected_revision,
                &conflicts,
            )
            .await?;
    }
    if !reports_conflicts || conflict_fields.is_empty() {
        return Ok(false);
    }
    operations.push(operation(OperationDraft {
        provider,
        action: ExternalSyncAction::Conflict,
        board_item_id: Some(item.id.clone()),
        reference: task.reference.clone(),
        dry_run: options.dry_run,
        applied: false,
        changed_fields: conflict_fields.to_vec(),
        unsupported_fields: Vec::new(),
    }));
    Ok(true)
}

/// The just-applied patch is simulated onto a clone rather than re-read from
/// storage, so convergence still reflects this write without a second point
/// read.
#[expect(
    clippy::too_many_arguments,
    reason = "finishes one already-decomposed reconcile call"
)]
async fn record_reconciliation_write(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: &ExternalTask,
    conflict_fields: &[ExternalSyncField],
    changed_fields: Vec<ExternalSyncField>,
    hierarchy_changed: bool,
    patch_for_convergence: TaskBoardItemPatch,
    applied_revision: i64,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let records_applied_operation = hierarchy_changed
        || !changed_fields.is_empty()
        || conflict_fields.is_empty()
        || !matches!(
            options.conflict_policy,
            ExternalSyncConflictPolicy::PreferLocal
        );
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
    let mut post_patch_item = item.clone();
    apply_patch(&mut post_patch_item, patch_for_convergence);
    supersede_resolved_conflicts(
        board,
        options,
        provider,
        &post_patch_item,
        task,
        conflict_fields,
        applied_revision,
    )
    .await
}

/// Returns the resulting revision without a point read. A concurrent writer
/// makes this sync pass fail closed; the next batch snapshot retries it.
async fn apply_reconciliation(
    board: &dyn TaskBoardSyncStore,
    item: &TaskBoardItem,
    expected_revision: i64,
    patch: TaskBoardItemPatch,
) -> Result<i64, CliError> {
    let updated = board.update_item(item, patch).await?;
    Ok(if updated == *item {
        expected_revision
    } else {
        expected_revision + 1
    })
}

async fn supersede_resolved_conflicts(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: &ExternalTask,
    conflict_fields: &[ExternalSyncField],
    item_revision: i64,
) -> Result<(), CliError> {
    if options.dry_run || !conflicts_are_resolved(options, conflict_fields) {
        return Ok(());
    }
    let resolved_fields = converged_pull_fields(item, task);
    board
        .supersede_open_sync_conflicts(
            &item.id,
            provider,
            &task.reference.external_id,
            item_revision,
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

fn has_reconciliation_change(patch: &TaskBoardItemPatch) -> bool {
    patch.title.is_some()
        || patch.body.is_some()
        || patch.status.is_some()
        || !matches!(patch.project_id, OptionalFieldPatch::Unchanged)
        || !matches!(patch.execution_repository, OptionalFieldPatch::Unchanged)
        || patch.external_refs.is_some()
        || hierarchy_fields_changed(patch)
}

/// `changed_fields()` only reports title/body/status/project, so a patch
/// that touches only tags, kind, or parent looks field-less to callers that
/// gate on it (for example, whether a `PreferLocal` conflict still counts as
/// an applied operation). This lets them ask about hierarchy fields too.
fn hierarchy_fields_changed(patch: &TaskBoardItemPatch) -> bool {
    patch.kind.is_some()
        || patch.tags.is_some()
        || !matches!(patch.parent_item_id, OptionalFieldPatch::Unchanged)
}

#[cfg(test)]
mod tests;
