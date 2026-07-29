use harness_kernel::errors::CliErrorKind;
use sqlx::{Sqlite, Transaction};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::super::items::{
    apply_task_board_item_status_transition_in_tx, bump_change_in_tx,
    load_item_with_triage_override_in_tx,
};
use super::super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, replace_with_lane_transition_in_tx,
};
use super::super::triage_apply::{
    EnsuredTriageDecision, apply_override_placement_effect_in_tx, triage_eligible,
};
use super::super::triage_decisions::current_triage_decision_in_tx;
use super::super::triage_escalation_enqueue::maybe_enqueue_triage_escalation_in_tx;
use super::super::triage_override_audit::{
    record_triage_override_cleared_audit_in_tx, record_triage_override_set_audit_in_tx,
};
use super::{
    ClearReconciliation, TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideMutationResult,
    TaskBoardTriageOverrideSetInput, clear_triage_override_row_in_tx, ensure_expected_revision,
    ensure_expected_sequence_in_tx, reconcile_cleared_override_in_tx, write_triage_override_in_tx,
};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{
    OVERRIDE_PLACEMENT_PRODUCER, TaskBoardItem, TaskBoardTriageEffectiveOutcome,
    TaskBoardTriageEscalationConfig, TaskBoardTriageOverride, TriageVerdict,
    effective_triage_outcome,
};

/// Prove the item-list sequence and item-revision CAS pair, load the item
/// together with the override already stored on its row, and refuse a
/// tombstoned item. `deleted_message` is the only guard whose wording differs
/// between a set and a clear.
async fn load_override_target_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    expected_items_change_seq: i64,
    expected_item_revision: i64,
    deleted_message: &'static str,
) -> Result<(TaskBoardItem, i64, Option<TaskBoardTriageOverride>), CliError> {
    ensure_expected_sequence_in_tx(transaction, expected_items_change_seq).await?;
    let (item, revision, existing_override) =
        load_item_with_triage_override_in_tx(transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    ensure_expected_revision(&item.id, revision, expected_item_revision)?;
    if item.deleted_at.is_some() {
        return Err(CliErrorKind::invalid_transition(deleted_message).into());
    }
    Ok((item, revision, existing_override))
}

/// Everything a triage override set does inside the caller's transaction, so
/// the transaction itself settles at exactly one visible point in the caller.
pub(super) async fn apply_triage_override_set_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    input: &TaskBoardTriageOverrideSetInput,
) -> Result<TaskBoardTriageOverrideMutationResult, CliError> {
    let (item, revision, before_override) = load_override_target_in_tx(
        transaction,
        &input.item_id,
        input.expected_items_change_seq,
        input.expected_item_revision,
        "cannot set a triage override for a deleted task-board item",
    )
    .await?;
    if !triage_eligible(&item)
        || has_active_dispatch_reservation_in_tx(transaction, &item.id).await?
    {
        return Err(CliErrorKind::invalid_transition(
            "task-board item is not eligible for a triage override",
        )
        .into());
    }
    let before = item.clone();
    let before_decision = current_triage_decision_in_tx(transaction, &item.id).await?;
    let before_effective =
        effective_triage_outcome(before_override.as_ref(), before_decision.as_ref());
    let now = utc_now();
    let write = place_override_set_in_tx(
        transaction,
        item,
        before.clone(),
        revision,
        input.verdict,
        &now,
    )
    .await?;
    let override_ = TaskBoardTriageOverride {
        verdict: input.verdict,
        actor: input.actor.clone(),
        reason: input.reason.clone(),
        set_at: now,
    };
    let after_effective = effective_triage_outcome(Some(&override_), before_decision.as_ref());
    let items_change_seq = record_override_set_in_tx(
        transaction,
        &before,
        before_effective,
        &override_,
        after_effective,
        &write,
        input,
    )
    .await?;
    Ok(TaskBoardTriageOverrideMutationResult {
        item: write.item,
        item_revision: write.item_revision,
        items_change_seq,
        shifted: write.shifted,
        override_: Some(override_),
        effective: after_effective,
    })
}

/// Apply the override's placement effect, persist the status transition it
/// implies, and write the item row under its lane transition.
async fn place_override_set_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    mut item: TaskBoardItem,
    before: TaskBoardItem,
    revision: i64,
    verdict: TriageVerdict,
    now: &str,
) -> Result<LaneTransitionWrite, CliError> {
    let transition = apply_override_placement_effect_in_tx(
        transaction,
        &mut item,
        verdict,
        now,
        OVERRIDE_PLACEMENT_PRODUCER,
        true,
    )
    .await?;
    apply_task_board_item_status_transition_in_tx(transaction, &item).await?;
    replace_with_lane_transition_in_tx(transaction, before, revision, item, transition).await
}

/// Persist the override row itself, bump the item-list sequence, and audit
/// the set under the CAS pair the caller already proved.
async fn record_override_set_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    before_effective: Option<TaskBoardTriageEffectiveOutcome>,
    override_: &TaskBoardTriageOverride,
    after_effective: Option<TaskBoardTriageEffectiveOutcome>,
    write: &LaneTransitionWrite,
    input: &TaskBoardTriageOverrideSetInput,
) -> Result<i64, CliError> {
    write_triage_override_in_tx(
        transaction,
        &write.item.id,
        override_.verdict,
        &override_.actor,
        override_.reason.as_deref(),
        &override_.set_at,
    )
    .await?;
    let items_change_seq = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    record_triage_override_set_audit_in_tx(
        transaction,
        before,
        before_effective,
        override_,
        after_effective,
        write,
        items_change_seq,
        input.expected_item_revision,
        input.expected_items_change_seq,
    )
    .await?;
    Ok(items_change_seq)
}

/// Everything a triage override clear does inside the caller's transaction,
/// so the transaction itself settles at exactly one visible point in the
/// caller.
pub(super) async fn apply_triage_override_clear_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    input: &TaskBoardTriageOverrideClearInput,
    escalation_config: TaskBoardTriageEscalationConfig,
) -> Result<TaskBoardTriageOverrideMutationResult, CliError> {
    let (mut item, revision, existing_override) = load_override_target_in_tx(
        transaction,
        &input.item_id,
        input.expected_items_change_seq,
        input.expected_item_revision,
        "cannot clear a triage override for a deleted task-board item",
    )
    .await?;
    let Some(existing_override) = existing_override else {
        return Err(CliErrorKind::invalid_transition(
            "task-board item has no active triage override to clear",
        )
        .into());
    };
    if has_active_dispatch_reservation_in_tx(transaction, &item.id).await? {
        return Err(CliErrorKind::invalid_transition(
            "cannot clear a triage override while a dispatch reservation is active",
        )
        .into());
    }
    let before = item.clone();
    let now = utc_now();
    let reconciliation =
        reconcile_cleared_override_in_tx(transaction, &mut item, &existing_override, &now).await?;
    let write = place_override_clear_in_tx(
        transaction,
        item,
        before.clone(),
        revision,
        reconciliation.transition,
    )
    .await?;
    let items_change_seq = record_override_clear_in_tx(
        transaction,
        &before,
        &existing_override,
        &reconciliation,
        &write,
        input,
        escalation_config,
        &now,
    )
    .await?;
    Ok(TaskBoardTriageOverrideMutationResult {
        item: write.item,
        item_revision: write.item_revision,
        items_change_seq,
        shifted: write.shifted,
        override_: None,
        effective: reconciliation.after_effective,
    })
}

/// Persist the reconciled placement's status transition, write the item row
/// under its lane transition, and drop the override row itself.
async fn place_override_clear_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: TaskBoardItem,
    before: TaskBoardItem,
    revision: i64,
    transition: LaneTransitionKind,
) -> Result<LaneTransitionWrite, CliError> {
    apply_task_board_item_status_transition_in_tx(transaction, &item).await?;
    let write =
        replace_with_lane_transition_in_tx(transaction, before, revision, item, transition).await?;
    clear_triage_override_row_in_tx(transaction, &write.item.id).await?;
    Ok(write)
}

/// Bump the item-list sequence, enqueue an escalation for a freshly decided
/// automatic verdict, and audit the clear under the CAS pair the caller
/// already proved.
#[expect(
    clippy::too_many_arguments,
    reason = "one immutable audit row needs before/cleared/reconciliation/CAS/actor context together"
)]
async fn record_override_clear_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    cleared: &TaskBoardTriageOverride,
    reconciliation: &ClearReconciliation,
    write: &LaneTransitionWrite,
    input: &TaskBoardTriageOverrideClearInput,
    escalation_config: TaskBoardTriageEscalationConfig,
    now: &str,
) -> Result<i64, CliError> {
    let items_change_seq = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    if let Some(EnsuredTriageDecision::Decided(decision)) = reconciliation.decision.as_ref() {
        // The override this call just cleared is gone by construction --
        // override_active is always false here.
        maybe_enqueue_triage_escalation_in_tx(
            transaction,
            &write.item.id,
            decision,
            false,
            &escalation_config,
            now,
        )
        .await?;
    }
    record_triage_override_cleared_audit_in_tx(
        transaction,
        before,
        cleared,
        reconciliation.before_effective,
        reconciliation.after_effective,
        reconciliation.decision.as_ref(),
        reconciliation.reconciled,
        write,
        items_change_seq,
        input.expected_item_revision,
        input.expected_items_change_seq,
        &input.actor,
    )
    .await?;
    Ok(items_change_seq)
}
