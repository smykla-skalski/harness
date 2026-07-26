//! Write phases for provider-exclusion hide and restore: everything that runs
//! once the screen in `provider_exclusion.rs` has decided the transaction is
//! going to change rows.

use sqlx::{Sqlite, Transaction};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::items::{
    bump_change_in_tx, clear_children_parent_in_tx, load_item_in_tx, validate_item,
};
use super::super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, replace_with_lane_transition_in_tx,
};
use super::super::triage_apply::TriageOutcome;
use super::super::triage_audit::{
    ProviderExclusionConflictAudit, record_provider_exclusion_hidden_audit_in_tx,
    record_provider_exclusion_restored_audit_in_tx,
};
use super::super::triage_escalation_enqueue::maybe_enqueue_triage_escalation_in_tx;
use super::{
    is_hideable_for_provider_exclusion_in_tx, item_has_stored_provider_ref,
    reconcile_restore_triage_in_tx, record_hide_conflicts_in_tx, resolve_restore_parent_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error, utc_now};
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    ProviderExclusionAuditContext, TaskBoardItem, TaskBoardSyncConflict, TaskBoardTombstoneCause,
    TaskBoardTriageOverride, canonicalize_labels, is_exclusion_label,
};

/// What the hide screen decided, and everything the tombstoning write needs.
pub(super) enum HidePreparation {
    Ready(Box<PreparedHide>),
    NotApplied,
}

pub(super) struct PreparedHide {
    before: TaskBoardItem,
    item: TaskBoardItem,
    revision: i64,
    conflict_audit: ProviderExclusionConflictAudit,
}

/// Screens the hide and applies `patch`, stopping before any row is
/// tombstoned. `NotApplied` means the screen read nothing it could hide and
/// wrote nothing, so the caller's commit settles an empty transaction.
pub(super) async fn prepare_hide_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    expected_revision: i64,
    patch: TaskBoardItemPatch,
    context: &ProviderExclusionAuditContext,
    conflicts: Option<&[TaskBoardSyncConflict]>,
) -> Result<HidePreparation, CliError> {
    let Some((item, revision)) =
        load_hide_candidate_in_tx(transaction, item_id, expected_revision, context).await?
    else {
        return Ok(HidePreparation::NotApplied);
    };
    let before = item.clone();
    let mut item = item;
    apply_patch(&mut item, patch);
    // The context's claim alone isn't proof the patched row carries the
    // label; tombstoning on a false claim hides under false evidence.
    if !canonicalize_labels(&item.tags).contains(&context.matched_label) {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board item '{item_id}' hide patch does not carry the matched exclusion label '{}'",
            context.matched_label
        ))
        .into());
    }
    // Runs before the tombstoning write, while the row's revision still
    // matches `expected_revision`.
    let conflict_audit =
        record_hide_conflicts_in_tx(transaction, item_id, expected_revision, context, conflicts)
            .await?;
    Ok(HidePreparation::Ready(Box::new(PreparedHide {
        before,
        item,
        revision,
        conflict_audit,
    })))
}

async fn load_hide_candidate_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    expected_revision: i64,
    context: &ProviderExclusionAuditContext,
) -> Result<Option<(TaskBoardItem, i64)>, CliError> {
    let Some((item, revision)) = load_item_in_tx(transaction, item_id).await? else {
        return Err(db_error(format!("task-board item '{item_id}' not found")));
    };
    if revision != expected_revision
        || !is_exclusion_label(&context.matched_label)
        || !item_has_stored_provider_ref(&item, context)
        || !is_hideable_for_provider_exclusion_in_tx(transaction, &item).await?
    {
        return Ok(None);
    }
    Ok(Some((item, revision)))
}

/// Tombstones the screened item, unparents its children and records the one
/// hidden audit event. Returns the lane write and the items change revision,
/// so the caller commits and reports the mutation.
pub(super) async fn apply_exclusion_tombstone_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    prepared: PreparedHide,
    context: &ProviderExclusionAuditContext,
) -> Result<(LaneTransitionWrite, i64), CliError> {
    let PreparedHide {
        before,
        mut item,
        revision,
        conflict_audit,
    } = prepared;
    item.deleted_at = Some(utc_now());
    item.tombstone_cause = Some(TaskBoardTombstoneCause::ProviderExclusion);
    item.updated_at = utc_now();
    validate_item(&item)?;
    let unparented_children = clear_children_parent_in_tx(transaction, &before.id).await?;
    let write = replace_with_lane_transition_in_tx(
        transaction,
        before.clone(),
        revision,
        item,
        LaneTransitionKind::ProviderExclusionHide,
    )
    .await?;
    let change_revision = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    record_provider_exclusion_hidden_audit_in_tx(
        transaction,
        context,
        &conflict_audit,
        &before,
        &unparented_children,
        &write,
        change_revision,
    )
    .await?;
    Ok((write, change_revision))
}

/// The screened restore's audit inputs, which every step of its write phase
/// reads and none of them changes.
pub(super) struct RestoreAudit<'a> {
    pub(super) context: &'a ProviderExclusionAuditContext,
    pub(super) conflict_audit: &'a ProviderExclusionConflictAudit,
    pub(super) existing_override: Option<&'a TaskBoardTriageOverride>,
}

struct RestoredWrite<'a> {
    before: &'a TaskBoardItem,
    before_parent_item_id: Option<&'a str>,
    outcome: Option<&'a TriageOutcome>,
    write: &'a LaneTransitionWrite,
    change_revision: i64,
    decided_at: &'a str,
}

impl AsyncDaemonDb {
    /// Revives the screened tombstone, reconciles its triage placement and
    /// records the one restored audit event. The caller commits.
    pub(super) async fn write_provider_exclusion_restore_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: TaskBoardItem,
        revision: i64,
        patch: TaskBoardItemPatch,
        audit: &RestoreAudit<'_>,
    ) -> Result<TaskBoardItem, CliError> {
        let before = item.clone();
        let before_parent_item_id = item.parent_item_id.clone();
        let mut item = item;
        revive_restored_item_in_tx(transaction, &mut item, patch, &before).await?;
        let decided_at = item.updated_at.clone();
        let (outcome, transition_kind) = reconcile_restore_triage_in_tx(
            transaction,
            &mut item,
            audit.existing_override,
            &decided_at,
        )
        .await?;
        let write = replace_with_lane_transition_in_tx(
            transaction,
            before.clone(),
            revision,
            item,
            transition_kind,
        )
        .await?;
        let change_revision = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
        self.record_restore_settlement_in_tx(
            transaction,
            audit,
            &RestoredWrite {
                before: &before,
                before_parent_item_id: before_parent_item_id.as_deref(),
                outcome: outcome.as_ref(),
                write: &write,
                change_revision,
                decided_at: &decided_at,
            },
        )
        .await?;
        Ok(write.item)
    }

    async fn record_restore_settlement_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        audit: &RestoreAudit<'_>,
        settled: &RestoredWrite<'_>,
    ) -> Result<(), CliError> {
        if let Some(TriageOutcome::Decided(decision)) = settled.outcome {
            maybe_enqueue_triage_escalation_in_tx(
                transaction,
                &settled.write.item.id,
                decision,
                audit.existing_override.is_some(),
                &self.triage_escalation_config(),
                settled.decided_at,
            )
            .await?;
        }
        record_provider_exclusion_restored_audit_in_tx(
            transaction,
            audit.context,
            audit.conflict_audit,
            settled.before,
            settled.before_parent_item_id,
            settled.outcome,
            settled.write,
            settled.change_revision,
        )
        .await
    }
}

/// Lifts the tombstone and applies the reconciliation patch. `before` is the
/// stored tombstone row, so the parent link and child order it carries are
/// what a rejected parent assignment falls back to.
async fn revive_restored_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    patch: TaskBoardItemPatch,
    before: &TaskBoardItem,
) -> Result<(), CliError> {
    item.deleted_at = None;
    item.tombstone_cause = None;
    item.updated_at = utc_now();
    apply_patch(item, patch);
    if canonicalize_labels(&item.tags)
        .iter()
        .any(|label| is_exclusion_label(label))
    {
        return Err(CliErrorKind::workflow_io(format!(
            "provider-exclusion restore for '{}' still carries an exclusion label",
            before.id
        ))
        .into());
    }
    resolve_restore_parent_in_tx(
        transaction,
        &before.id,
        item,
        before.parent_item_id.as_deref(),
        before.child_order,
    )
    .await?;
    validate_item(item)
}
