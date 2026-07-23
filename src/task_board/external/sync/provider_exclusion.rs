use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProvider, ExternalSyncField, ExternalTask, ProviderExclusionAuditContext,
    ProviderExclusionRestoreOutcome,
};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{ExternalRef, TaskBoardItem};

use super::conflicts::build_sync_conflicts;
use super::lookup::ProviderItemIndex;
use super::merge::{changed_fields, matching_ref, pull_conflict_fields};
use super::reconcile::reconciliation_patch;
use super::{
    ExternalSyncAction, ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncOperation,
    ExternalSyncOptions, OperationDraft, TaskBoardSyncStore, matched_exclusion_label, operation,
};

/// The same "prefer remote" rule ordinary reconcile uses, so a restore
/// resolves conflicting fields identically to any other pull.
fn prefer_remote(options: ExternalSyncOptions) -> bool {
    matches!(
        options.conflict_policy,
        ExternalSyncConflictPolicy::PreferRemote
    ) || matches!(options.direction, ExternalSyncDirection::Pull)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report)
}

/// The same "publish a conflict, apply nothing" gate ordinary reconcile uses
/// for `Both` direction under `Report` policy, so a restore whose fields
/// disagree with the provider is reported and left tombstoned instead of
/// silently reconciled.
fn reports_restore_conflicts(options: ExternalSyncOptions) -> bool {
    matches!(options.direction, ExternalSyncDirection::Both)
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report)
}

/// Reverts conflicting fields back to unchanged so hide never applies a
/// value it also reports as conflicting. `Url` lives inside `external_refs`,
/// not a standalone field, so it's left alone.
fn strip_conflicting_fields(patch: &mut TaskBoardItemPatch, conflict_fields: &[ExternalSyncField]) {
    for field in conflict_fields {
        match field {
            ExternalSyncField::Title => patch.title = None,
            ExternalSyncField::Body => patch.body = None,
            ExternalSyncField::Status => patch.status = None,
            ExternalSyncField::Project => patch.project_id = OptionalFieldPatch::Unchanged,
            ExternalSyncField::Url => {}
        }
    }
}

fn preserve_conflicting_sync_baseline(
    patch: &mut TaskBoardItemPatch,
    stored_ref: &ExternalRef,
    task: &ExternalTask,
    conflict_fields: &[ExternalSyncField],
) -> Result<(), CliError> {
    if conflict_fields.is_empty() {
        return Ok(());
    }
    let Some(refs) = patch.external_refs.as_mut() else {
        return Ok(());
    };
    let provider = stored_ref.provider;
    let next_ref = refs
        .iter_mut()
        .find(|reference| {
            reference.provider == provider && reference.external_id == task.reference.external_id
        })
        .ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "provider-exclusion hide patch omitted the matched external ref",
            ))
        })?;
    if conflict_fields.contains(&ExternalSyncField::Url) {
        next_ref.url.clone_from(&stored_ref.url);
    }
    if conflict_fields
        .iter()
        .all(|field| *field == ExternalSyncField::Url)
    {
        return Ok(());
    }
    let next_state = next_ref.sync_state.as_mut().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "provider-exclusion hide patch omitted provider sync state",
        ))
    })?;
    let prior_state = stored_ref.sync_state.as_ref();
    for field in conflict_fields {
        match field {
            ExternalSyncField::Title => {
                next_state.title = prior_state.and_then(|state| state.title.clone());
            }
            ExternalSyncField::Body => {
                next_state.body = prior_state.and_then(|state| state.body.clone());
            }
            ExternalSyncField::Status => {
                next_state.status = prior_state.and_then(|state| state.status);
            }
            ExternalSyncField::Project => {
                next_state.project_id = prior_state.and_then(|state| state.project_id.clone());
            }
            ExternalSyncField::Url => {}
        }
    }
    Ok(())
}

/// The fields an applied Pull operation should report: whatever `patch`
/// actually changes, plus `Status` unconditionally (the tombstone toggle
/// itself, which isn't a patch field), in stable `ExternalSyncField` order.
fn applied_pull_fields(patch: &TaskBoardItemPatch) -> Vec<ExternalSyncField> {
    let applied = changed_fields(patch);
    [
        ExternalSyncField::Title,
        ExternalSyncField::Body,
        ExternalSyncField::Status,
        ExternalSyncField::Project,
    ]
    .into_iter()
    .filter(|field| *field == ExternalSyncField::Status || applied.contains(field))
    .collect()
}

fn provider_exclusion_context(
    provider: ExternalProvider,
    task: &ExternalTask,
    stored_external_ref: String,
    matched_label: String,
) -> ProviderExclusionAuditContext {
    ProviderExclusionAuditContext {
        provider: provider.into(),
        incoming_external_ref: task.reference.external_id.clone(),
        stored_external_ref,
        matched_label,
    }
}

fn record_restore_outcome(
    outcome: ProviderExclusionRestoreOutcome,
    provider: ExternalProvider,
    stored_id: &str,
    task: &ExternalTask,
    conflict_fields: Vec<ExternalSyncField>,
    applied_fields: Vec<ExternalSyncField>,
    operations: &mut Vec<ExternalSyncOperation>,
) {
    let draft = match outcome {
        ProviderExclusionRestoreOutcome::NotApplied => return,
        ProviderExclusionRestoreOutcome::ConflictPublished => OperationDraft {
            provider,
            action: ExternalSyncAction::Conflict,
            board_item_id: Some(stored_id.to_string()),
            reference: task.reference.clone(),
            dry_run: false,
            applied: false,
            changed_fields: conflict_fields,
            unsupported_fields: Vec::new(),
        },
        ProviderExclusionRestoreOutcome::Restored(restored) => OperationDraft {
            provider,
            action: ExternalSyncAction::Pull,
            board_item_id: Some(restored.id),
            reference: task.reference.clone(),
            dry_run: false,
            applied: true,
            changed_fields: applied_fields,
            unsupported_fields: Vec::new(),
        },
    };
    operations.push(operation(draft));
}

/// Tombstones an already-visible, pre-dispatch item because the provider now
/// reports an exclusion label. Applies the normal reconciliation patch first
/// so the tombstoned row carries the label that triggered the exclusion and
/// a refreshed `sync_state`, letting a later restore recover both instead of
/// comparing against a stale pre-exclusion baseline. Parent linkage is left
/// untouched -- out of scope for a hide. `matched_label` is the canonical
/// exclusion label the caller already confirmed is present.
#[expect(
    clippy::too_many_arguments,
    reason = "the sync boundary carries provider context, CAS state, evidence, and operation output"
)]
pub(super) async fn hide_existing_item_for_exclusion(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    expected_revision: i64,
    task: ExternalTask,
    matched_label: String,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let conflict_fields = if reports_restore_conflicts(options) {
        pull_conflict_fields(item, &task)
    } else {
        Vec::new()
    };
    let Some(stored_ref) = matching_ref(item, &task.reference, task.project_id.as_deref()) else {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board item '{}' matched a provider-exclusion hide but no external ref resolved",
            item.id
        ))
        .into());
    };
    let mut patch = reconciliation_patch(item, &task, prefer_remote(options), None);
    patch.parent_item_id = OptionalFieldPatch::Unchanged;
    // Hide's patch always applies, so a reported conflict field must be
    // stripped -- without a sync baseline, reconciliation_patch would
    // otherwise still overwrite it.
    strip_conflicting_fields(&mut patch, &conflict_fields);
    preserve_conflicting_sync_baseline(&mut patch, stored_ref, &task, &conflict_fields)?;
    let applied_fields = applied_pull_fields(&patch);
    if options.dry_run {
        if !conflict_fields.is_empty() {
            operations.push(operation(OperationDraft {
                provider,
                action: ExternalSyncAction::Conflict,
                board_item_id: Some(item.id.clone()),
                reference: task.reference.clone(),
                dry_run: true,
                applied: false,
                changed_fields: conflict_fields,
                unsupported_fields: Vec::new(),
            }));
        }
        operations.push(operation(OperationDraft {
            provider,
            action: ExternalSyncAction::Pull,
            board_item_id: Some(item.id.clone()),
            reference: task.reference,
            dry_run: true,
            applied: false,
            changed_fields: applied_fields,
            unsupported_fields: Vec::new(),
        }));
        return Ok(());
    }
    let context = provider_exclusion_context(
        provider,
        &task,
        stored_ref.external_id.clone(),
        matched_label,
    );
    // Exclusion visibility is unconditional, so unlike restore this never
    // blocks on `Some(non-empty)`; it only decides whether the hide also
    // publishes/supersedes conflict rows in the same transaction.
    let conflicts = reports_restore_conflicts(options).then(|| {
        if conflict_fields.is_empty() {
            Vec::new()
        } else {
            build_sync_conflicts(item, &task, &conflict_fields, expected_revision)
        }
    });
    let hidden = board
        .hide_for_provider_exclusion(&item.id, expected_revision, patch, context, conflicts)
        .await?;
    if hidden.is_some() {
        // Both facts must be reported when they both occurred: the
        // conflicting fields the hide did not apply, and the exclusion
        // hide itself, which always proceeds regardless.
        if !conflict_fields.is_empty() {
            operations.push(operation(OperationDraft {
                provider,
                action: ExternalSyncAction::Conflict,
                board_item_id: Some(item.id.clone()),
                reference: task.reference.clone(),
                dry_run: false,
                applied: false,
                changed_fields: conflict_fields,
                unsupported_fields: Vec::new(),
            }));
        }
        operations.push(operation(OperationDraft {
            provider,
            action: ExternalSyncAction::Pull,
            board_item_id: Some(item.id.clone()),
            reference: task.reference,
            dry_run: false,
            applied: true,
            changed_fields: applied_fields,
            unsupported_fields: Vec::new(),
        }));
    }
    Ok(())
}

/// A "new" provider task whose canonical or legacy-alias reference matches
/// an item already tombstoned for provider exclusion means the provider
/// un-excluded it: restore it in place by its actual stored id (never a
/// regenerated deterministic id, which would break a legacy or manually
/// assigned one), reconciling provider-owned fields with the exact same
/// `reconciliation_patch` an ordinary pull reconcile computes so a restore
/// preserves or conflicts identically instead of unconditionally overwriting
/// local state. `index` is the single batch-loaded lookup built once per
/// pull; this never issues its own point read. A dry run reports the actual
/// stored id through the same index without writing anything. Not eligible
/// restores (no matching excluded snapshot) fall through to a normal create.
pub(super) async fn try_restore_provider_exclusion_tombstone(
    board: &dyn TaskBoardSyncStore,
    index: &ProviderItemIndex,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    task: &ExternalTask,
    resolved_parent_item_id: Option<String>,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<bool, CliError> {
    let Some(expected) = index.excluded_snapshot(&task.reference, task.project_id.as_deref())?
    else {
        return Ok(false);
    };
    let stored = &expected.item;
    // The index already matched this ref; a miss here is a broken invariant,
    // not ineligibility -- `Ok(false)` would risk creating a duplicate.
    let Some(stored_ref) = matching_ref(stored, &task.reference, task.project_id.as_deref()) else {
        return Err(CliErrorKind::workflow_io(format!(
            "provider-exclusion tombstone '{}' matched the index but no external ref resolved",
            stored.id
        ))
        .into());
    };
    // A tombstone whose own tags no longer carry a recoverable canonical
    // exclusion label is corrupt, not merely ineligible: falling through to
    // a normal create here would risk a duplicate or a confusing collision,
    // so this fails closed instead.
    let Some(matched_label) = matched_exclusion_label(&stored.tags) else {
        return Err(CliErrorKind::workflow_io(format!(
            "provider-exclusion tombstone '{}' lost its canonical exclusion label",
            stored.id
        ))
        .into());
    };
    let context = provider_exclusion_context(
        provider,
        task,
        stored_ref.external_id.clone(),
        matched_label,
    );
    let conflict_fields = if reports_restore_conflicts(options) {
        pull_conflict_fields(stored, task)
    } else {
        Vec::new()
    };
    let has_conflicts = !conflict_fields.is_empty();
    let patch: TaskBoardItemPatch = reconciliation_patch(
        stored,
        task,
        prefer_remote(options),
        resolved_parent_item_id.as_deref(),
    );
    let applied_fields = applied_pull_fields(&patch);
    if options.dry_run {
        operations.push(operation(OperationDraft {
            provider,
            action: if has_conflicts {
                ExternalSyncAction::Conflict
            } else {
                ExternalSyncAction::Pull
            },
            board_item_id: Some(stored.id.clone()),
            reference: task.reference.clone(),
            dry_run: true,
            applied: false,
            changed_fields: if has_conflicts {
                conflict_fields
            } else {
                applied_fields
            },
            unsupported_fields: Vec::new(),
        }));
        return Ok(true);
    }
    // `None` when this restore isn't under Both+Report at all, so the DB
    // layer leaves any conflict rows untouched; `Some` (empty or not) once
    // it is, so a round that stops conflicting still supersedes stale ones
    // in the same transaction as the restore.
    let conflicts = reports_restore_conflicts(options).then(|| {
        if has_conflicts {
            build_sync_conflicts(stored, task, &conflict_fields, expected.item_revision)
        } else {
            Vec::new()
        }
    });
    let outcome = board
        .restore_from_provider_exclusion(expected.clone(), patch, context, conflicts)
        .await?;
    // Driven by what the DB layer actually did, not by this call's own
    // pre-computed `has_conflicts` -- a stale/no-op CAS must never be
    // mistaken for a published conflict, or the caller could fall through
    // to create a duplicate for an item that is still tombstoned.
    // The batch index already proved this provider ref belonged to an
    // excluded item. A transaction-level miss means that snapshot went
    // stale, not that create is now safe; the next pull batch reloads the
    // index and chooses between reconcile, restore, and create.
    record_restore_outcome(
        outcome,
        provider,
        &stored.id,
        task,
        conflict_fields,
        applied_fields,
        operations,
    );
    Ok(true)
}

#[cfg(test)]
#[path = "provider_exclusion/tests.rs"]
mod tests;
