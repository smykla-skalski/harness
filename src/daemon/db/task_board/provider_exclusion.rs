use sqlx::{Sqlite, Transaction};

use self::write::{
    HidePreparation, RestoreAudit, apply_exclusion_tombstone_in_tx, prepare_hide_in_tx,
};
use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::items::{
    ParentAssignmentValidation, TaskBoardMutation, bump_change_in_tx,
    check_parent_assignment_in_tx, load_item_with_triage_override_in_tx, next_child_order_in_tx,
};
use super::lane_order::LaneTransitionKind;
use super::provider_sync_conflicts::replace_open_sync_conflicts_in_connection;
use super::triage_apply::{TriageOutcome, reapply_active_override_outcome_in_tx};
use super::triage_apply_rules::apply_active_triage_in_tx;
use super::triage_audit::ProviderExclusionConflictAudit;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error};
use crate::infra::io;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::TaskBoardItemKind;
use crate::task_board::{
    ExternalProvider, ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome,
    TaskBoardItem, TaskBoardStatus, TaskBoardSyncConflict, TaskBoardTombstoneCause,
    TaskBoardTriageOverride, canonicalize_labels, is_exclusion_label,
};

impl AsyncDaemonDb {
    /// Tombstones an already-visible, pre-dispatch item because the provider
    /// now reports an exclusion label. `expected_revision` and `context`'s
    /// stored provider ref both CAS against the exact state the caller
    /// matched by; either moving means `None`, doing nothing. Also `None`
    /// when the item is not eligible to be hidden this way: already deleted,
    /// past pre-dispatch, or carrying durable dispatch/admission evidence of
    /// claimed or started work. `patch` (the normal reconciliation patch,
    /// minus parent) is applied before tombstoning, so the row it stores
    /// carries the label that triggered the exclusion and a fresh
    /// `sync_state` for a later restore to recover. Records exactly one
    /// typed audit event, with every child unparented in the same
    /// transaction, even when the item has no lane anchor to change.
    pub(crate) async fn hide_task_board_item_for_provider_exclusion(
        &self,
        item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<Option<TaskBoardMutation>, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board provider exclusion hide")
            .await?;
        let prepared = match prepare_hide_in_tx(
            &mut transaction,
            item_id,
            expected_revision,
            patch,
            context,
            conflicts.as_deref(),
        )
        .await?
        {
            HidePreparation::Ready(prepared) => prepared,
            HidePreparation::NotApplied => {
                transaction
                    .commit()
                    .await
                    .map_err(|error| db_error(format!("commit task board hide no-op: {error}")))?;
                return Ok(None);
            }
        };
        let (write, change_revision) =
            apply_exclusion_tombstone_in_tx(&mut transaction, *prepared, context).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board hide: {error}")))?;
        Ok(Some(TaskBoardMutation {
            item: write.item,
            item_revision: write.item_revision,
            change_revision,
        }))
    }

    /// Restores a previously provider-exclusion-tombstoned item because the
    /// provider no longer reports an exclusion label. `expected_revision`
    /// and `context`'s stored provider ref both CAS against the exact state
    /// the caller matched by; either moving, or the row no longer carrying
    /// the `ProviderExclusion` cause, yields `NotApplied`. `patch` is the
    /// normal reconciliation patch (parent tri-state included) applied the
    /// same way any other reconcile applies one, so local state it never
    /// mentions -- planning approval, workflow, session, work item linkage,
    /// estimates, agent mode, a `Manual` lane anchor -- stays exactly as
    /// stored. A rejected parent assignment (self, cycle, missing) is
    /// isolated to that field, same as ordinary reconcile; the rest of the
    /// patch still applies. A retained `BuiltInV1` decision's placement
    /// effect is reconciled here too, without duplicating decision history,
    /// and the whole restore is exactly one typed audit event. `conflicts`
    /// is `None` outside `Both`+`Report` (conflict state untouched),
    /// `Some(empty)` to supersede stale open rows in this same transaction
    /// before the restore proceeds, or `Some(non-empty)` to publish
    /// conflicts and return `ConflictPublished` without restoring, leaving
    /// the tombstone in place.
    pub(crate) async fn restore_task_board_item_for_provider_exclusion(
        &self,
        expected_item_id: &str,
        expected_revision: i64,
        patch: TaskBoardItemPatch,
        context: &ProviderExclusionAuditContext,
        conflicts: Option<Vec<TaskBoardSyncConflict>>,
    ) -> Result<ProviderExclusionRestoreOutcome, CliError> {
        io::validate_safe_segment(expected_item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board provider exclusion restore")
            .await?;
        let (item, revision, existing_override, conflict_audit) = match prepare_restore_in_tx(
            &mut transaction,
            expected_item_id,
            expected_revision,
            context,
            conflicts.as_deref(),
        )
        .await?
        {
            RestorePreparation::Ready {
                item,
                revision,
                existing_override,
                conflict_audit,
            } => (*item, revision, existing_override, conflict_audit),
            RestorePreparation::Done(outcome) => {
                return commit_restore_no_op(transaction, outcome, "no-op").await;
            }
        };
        let restored = self
            .write_provider_exclusion_restore_in_tx(
                &mut transaction,
                item,
                revision,
                patch,
                &RestoreAudit {
                    context,
                    conflict_audit: &conflict_audit,
                    existing_override: existing_override.as_ref(),
                },
            )
            .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board restore: {error}")))?;
        Ok(ProviderExclusionRestoreOutcome::Restored(Box::new(
            restored,
        )))
    }
}

#[path = "provider_exclusion_write.rs"]
mod write;

/// Replaces the item's open sync conflicts for a hide, and reports what the
/// replacement changed so the hidden audit event can carry it. A hide records
/// conflicts and proceeds; only a restore is blocked by them.
async fn record_hide_conflicts_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    expected_revision: i64,
    context: &ProviderExclusionAuditContext,
    conflicts: Option<&[TaskBoardSyncConflict]>,
) -> Result<ProviderExclusionConflictAudit, CliError> {
    let Some(conflicts) = conflicts else {
        return Ok(ProviderExclusionConflictAudit::new(None, &[], None));
    };
    let replacement = replace_open_sync_conflicts_in_connection(
        transaction.as_mut(),
        item_id,
        ExternalProvider::from(context.provider),
        &context.incoming_external_ref,
        expected_revision,
        conflicts,
    )
    .await?;
    let orchestrator_change_seq = if replacement.changed() {
        Some(bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?)
    } else {
        None
    };
    Ok(ProviderExclusionConflictAudit::new(
        Some(conflicts),
        replacement.changed_fields(),
        orchestrator_change_seq,
    ))
}

enum RestoreConflictAction {
    Continue(ProviderExclusionConflictAudit),
    Block,
}

async fn load_provider_exclusion_restore_candidate_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    expected_revision: i64,
    context: &ProviderExclusionAuditContext,
) -> Result<Option<(TaskBoardItem, i64, Option<TaskBoardTriageOverride>)>, CliError> {
    let Some((item, revision, override_)) =
        load_item_with_triage_override_in_tx(transaction, item_id).await?
    else {
        return Ok(None);
    };
    if revision != expected_revision
        || item.tombstone_cause != Some(TaskBoardTombstoneCause::ProviderExclusion)
        || !is_exclusion_label(&context.matched_label)
        || !item_has_stored_provider_ref(&item, context)
    {
        return Ok(None);
    }
    if !canonicalize_labels(&item.tags).contains(&context.matched_label) {
        return Err(CliErrorKind::workflow_io(format!(
            "provider-exclusion tombstone '{item_id}' lost its canonical exclusion label"
        ))
        .into());
    }
    Ok(Some((item, revision, override_)))
}

async fn apply_restore_conflicts_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    expected_revision: i64,
    context: &ProviderExclusionAuditContext,
    conflicts: Option<&[TaskBoardSyncConflict]>,
) -> Result<RestoreConflictAction, CliError> {
    let Some(conflicts) = conflicts else {
        return Ok(RestoreConflictAction::Continue(
            ProviderExclusionConflictAudit::new(None, &[], None),
        ));
    };
    let replacement = replace_open_sync_conflicts_in_connection(
        transaction.as_mut(),
        item_id,
        ExternalProvider::from(context.provider),
        &context.incoming_external_ref,
        expected_revision,
        conflicts,
    )
    .await?;
    let orchestrator_change_seq = if replacement.changed() {
        Some(bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?)
    } else {
        None
    };
    if !conflicts.is_empty() {
        return Ok(RestoreConflictAction::Block);
    }
    Ok(RestoreConflictAction::Continue(
        ProviderExclusionConflictAudit::new(
            Some(conflicts),
            replacement.changed_fields(),
            orchestrator_change_seq,
        ),
    ))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "accepting or rejecting a restored parent link scores 3 structurally; \
              the one tracing::warn! reporting the rejected link expands to 7 more \
              points on its own, so no split reaches the threshold of 7"
)]
async fn resolve_restore_parent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    item: &mut TaskBoardItem,
    previous_parent_id: Option<&str>,
    previous_child_order: u32,
) -> Result<(), CliError> {
    if item.parent_item_id.as_deref() == previous_parent_id {
        return Ok(());
    }
    let Some(parent_id) = item.parent_item_id.clone() else {
        item.child_order = 0;
        return Ok(());
    };
    match check_parent_assignment_in_tx(transaction, item_id, &parent_id).await? {
        ParentAssignmentValidation::Valid => {
            item.child_order = next_child_order_in_tx(transaction, &parent_id).await?;
        }
        ParentAssignmentValidation::Invalid(reason) => {
            tracing::warn!(
                item_id,
                reason,
                "provider exclusion restore: rejected parent link"
            );
            item.parent_item_id = previous_parent_id.map(str::to_owned);
            item.child_order = previous_child_order;
        }
    }
    Ok(())
}

/// Whether `item` still carries the exact external ref `context` matched it
/// by -- an extra guard beyond the revision CAS, so a hide or restore never
/// acts on a row whose provider link changed underneath it even if the
/// revision number happened to coincide.
fn item_has_stored_provider_ref(
    item: &TaskBoardItem,
    context: &ProviderExclusionAuditContext,
) -> bool {
    item.external_refs.iter().any(|reference| {
        reference.provider == context.provider
            && reference.external_id == context.stored_external_ref
    })
}

enum RestorePreparation {
    Ready {
        item: Box<TaskBoardItem>,
        revision: i64,
        existing_override: Option<TaskBoardTriageOverride>,
        conflict_audit: ProviderExclusionConflictAudit,
    },
    Done(ProviderExclusionRestoreOutcome),
}

/// Loads the restore candidate and applies conflict resolution -- the two
/// steps that can each end the restore early. `Done` means the caller
/// commits the no-op and returns; `Ready` carries what the rest needs.
async fn prepare_restore_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_item_id: &str,
    expected_revision: i64,
    context: &ProviderExclusionAuditContext,
    conflicts: Option<&[TaskBoardSyncConflict]>,
) -> Result<RestorePreparation, CliError> {
    let Some((item, revision, existing_override)) =
        load_provider_exclusion_restore_candidate_in_tx(
            transaction,
            expected_item_id,
            expected_revision,
            context,
        )
        .await?
    else {
        return Ok(RestorePreparation::Done(
            ProviderExclusionRestoreOutcome::NotApplied,
        ));
    };
    let conflict_audit = match apply_restore_conflicts_in_tx(
        transaction,
        expected_item_id,
        expected_revision,
        context,
        conflicts,
    )
    .await?
    {
        RestoreConflictAction::Continue(audit) => audit,
        RestoreConflictAction::Block => {
            return Ok(RestorePreparation::Done(
                ProviderExclusionRestoreOutcome::ConflictPublished,
            ));
        }
    };
    Ok(RestorePreparation::Ready {
        item: Box::new(item),
        revision,
        existing_override,
        conflict_audit,
    })
}

/// Commits a restore transaction that has nothing left to write (no
/// candidate found, or a conflict publish superseded the restore) and
/// returns the outcome the caller already decided on.
async fn commit_restore_no_op(
    transaction: Transaction<'_, Sqlite>,
    outcome: ProviderExclusionRestoreOutcome,
    reason: &str,
) -> Result<ProviderExclusionRestoreOutcome, CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board restore {reason}: {error}")))?;
    Ok(outcome)
}

fn triage_changed_placement(before: &TaskBoardItem, after: &TaskBoardItem) -> bool {
    before.status != after.status
        || before.lane_position != after.lane_position
        || before.lane_origin != after.lane_origin
        || before.lane_set_at != after.lane_set_at
}

/// Evaluates `BuiltInV1` for a restored item and decides the lane-transition
/// kind to write with. `item` is the post-patch snapshot, before triage --
/// comparing against the still-tombstoned `before` row would make every
/// restore look like a lane move. An active override still wins over the
/// refreshed decision alone.
async fn reconcile_restore_triage_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    existing_override: Option<&TaskBoardTriageOverride>,
    decided_at: &str,
) -> Result<(Option<TriageOutcome>, LaneTransitionKind), CliError> {
    let pre_triage_item = item.clone();
    let outcome =
        apply_active_triage_in_tx(transaction, item, decided_at, false, existing_override).await?;
    let override_reapply_transition =
        reapply_active_override_outcome_in_tx(transaction, item, existing_override, decided_at)
            .await?;
    let transition_kind = override_reapply_transition.unwrap_or_else(|| {
        if triage_changed_placement(&pre_triage_item, item) {
            LaneTransitionKind::Automatic
        } else {
            LaneTransitionKind::ProviderExclusionRestore
        }
    });
    Ok((outcome, transition_kind))
}

async fn is_hideable_for_provider_exclusion_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
) -> Result<bool, CliError> {
    if item.is_deleted()
        || item.work_item_id.is_some()
        || !matches!(
            &item.kind,
            TaskBoardItemKind::Task | TaskBoardItemKind::Umbrella
        )
    {
        return Ok(false);
    }
    if !matches!(
        item.status.canonical_persisted_status(),
        TaskBoardStatus::Backlog | TaskBoardStatus::Todo
    ) {
        return Ok(false);
    }
    Ok(!has_active_dispatch_reservation_in_tx(transaction, &item.id).await?)
}

#[cfg(test)]
#[path = "provider_exclusion_tests.rs"]
mod tests;
