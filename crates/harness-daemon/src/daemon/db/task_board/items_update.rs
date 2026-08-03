use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardTriageOverride};
use harness_kernel::errors::CliErrorKind;

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt;
use super::super::item_tx_ext::TaskBoardItemTxExt;
use super::super::lane_order::{LaneTransitionKind, replace_with_lane_transition_in_tx};
use super::super::projects::resolve_item_project_in_tx;
use super::super::triage_interface::Triage;
use super::lifecycle::ensure_estimates_are_editable_in_tx;
use super::{
    TaskBoardMutation, TaskBoardMutationKind, TaskBoardTriageIngress, TriageEvaluator,
    TriageOutcome, bump_change_in_tx, record_triage_or_lane_audit_in_tx,
    resolve_parent_update_in_tx, validate_item,
};
use crate::daemon::db::prelude::*;

#[derive(Clone, Copy, PartialEq, Eq)]
enum DispatchReservationPolicy {
    Allow,
    Skip,
}

pub(crate) async fn update_task_board_item<F>(
    db: &AsyncDaemonDb,
    item_id: &str,
    mutate: F,
) -> Result<Option<TaskBoardMutation>, CliError>
where
    F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
{
    update_task_board_item_impl(
        db,
        item_id,
        mutate,
        TaskBoardTriageIngress::None,
        DispatchReservationPolicy::Allow,
    )
    .await
}

pub(crate) async fn update_task_board_item_for_evaluation<F>(
    db: &AsyncDaemonDb,
    item_id: &str,
    mutate: F,
) -> Result<Option<TaskBoardMutation>, CliError>
where
    F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
{
    update_task_board_item_impl(
        db,
        item_id,
        mutate,
        TaskBoardTriageIngress::None,
        DispatchReservationPolicy::Skip,
    )
    .await
}

pub(crate) async fn update_task_board_item_with_triage<F>(
    db: &AsyncDaemonDb,
    item_id: &str,
    mutate: F,
) -> Result<Option<TaskBoardMutation>, CliError>
where
    F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
{
    update_task_board_item_impl(
        db,
        item_id,
        mutate,
        TaskBoardTriageIngress::HumanUpdate,
        DispatchReservationPolicy::Allow,
    )
    .await
}

pub(crate) async fn update_task_board_item_with_provider_triage<F>(
    db: &AsyncDaemonDb,
    item_id: &str,
    mutate: F,
) -> Result<Option<TaskBoardMutation>, CliError>
where
    F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
{
    update_task_board_item_impl(
        db,
        item_id,
        mutate,
        TaskBoardTriageIngress::ProviderReconcile,
        DispatchReservationPolicy::Allow,
    )
    .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "sequential mutation and guard chain with atomic triage and lane persistence"
)]
async fn update_task_board_item_impl<F>(
    db: &AsyncDaemonDb,
    item_id: &str,
    mutate: F,
    ingress: TaskBoardTriageIngress,
    reservation_policy: DispatchReservationPolicy,
) -> Result<Option<TaskBoardMutation>, CliError>
where
    F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
{
    io::validate_safe_segment(item_id)?;
    let mut transaction = db
        .begin_immediate_transaction("task board item update")
        .await?;
    let (mut item, revision, existing_override) = transaction
        .load_item_with_triage_override_in_tx(item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    if reservation_policy == DispatchReservationPolicy::Skip
        && transaction
            .has_active_dispatch_reservation_in_tx(item_id)
            .await?
    {
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit reserved task board item no-op: {error}")))?;
        return Ok(None);
    }
    let before = item.clone();
    let prior_estimates = (item.estimated_tokens, item.estimated_cost_microusd);
    if !mutate(&mut item)? {
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item no-op: {error}")))?;
        return Ok(None);
    }
    if item.id != item_id {
        return Err(db_error(format!(
            "task-board mutation cannot change item id '{item_id}' to '{}'",
            item.id
        )));
    }
    if prior_estimates != (item.estimated_tokens, item.estimated_cost_microusd) {
        ensure_estimates_are_editable_in_tx(&mut transaction, item_id).await?;
    }
    item.status = item.status.canonical_persisted_status();
    resolve_parent_update_in_tx(&mut transaction, &mut item, &before, ingress).await?;
    resolve_item_project_in_tx(&mut transaction, &mut item).await?;
    validate_item(&item)?;
    if item == before {
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item no-op: {error}")))?;
        return Ok(None);
    }
    item.updated_at = utc_now();
    transaction
        .apply_task_board_item_status_transition_in_tx(&item)
        .await?;
    if item.deleted_at.is_some() {
        transaction.clear_children_parent_in_tx(item_id).await?;
    }
    let (outcome, transition_kind) = apply_update_triage_in_tx(
        &mut transaction,
        &before,
        &mut item,
        ingress,
        existing_override.as_ref(),
    )
    .await?;
    let before_triage = before.clone();
    let write =
        replace_with_lane_transition_in_tx(&mut transaction, before, revision, item, transition_kind)
            .await?;
    let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
    let mutation_kind =
        (ingress != TaskBoardTriageIngress::None).then_some(TaskBoardMutationKind::Update);
    record_triage_or_lane_audit_in_tx(
        &mut transaction,
        &before_triage,
        outcome.as_ref(),
        mutation_kind,
        &write,
        change_revision,
        existing_override.is_some(),
        &db.triage_escalation_config(),
    )
    .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board item update: {error}")))?;
    Ok(Some(TaskBoardMutation {
        item: write.item,
        item_revision: write.item_revision,
        change_revision,
    }))
}

async fn apply_update_triage_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    before: &TaskBoardItem,
    item: &mut TaskBoardItem,
    ingress: TaskBoardTriageIngress,
    existing_override: Option<&TaskBoardTriageOverride>,
) -> Result<(Option<TriageOutcome>, LaneTransitionKind), CliError> {
    // `None` shares the same reject check as `HumanUpdate`: every internal
    // workflow write (planning approval, dispatch, ...) that lands the item
    // in Inbox/Todo must respect an active override too, not only the
    // public update API. `ProviderReconcile` is the sole exception --
    // it reasserts the override instead of rejecting, via its own path below.
    if matches!(
        ingress,
        TaskBoardTriageIngress::HumanUpdate | TaskBoardTriageIngress::None
    ) {
        reject_if_conflicts_with_active_override(before, item, existing_override)?;
    }
    if ingress == TaskBoardTriageIngress::HumanUpdate {
        clear_stale_automatic_placement_on_human_status_move(
            before.status.canonical_persisted_status(),
            item,
        );
    }
    let pre_triage_item = item.clone();
    let decided_at = item.updated_at.clone();
    let outcome = compute_triage_outcome_in_tx(
        transaction,
        before,
        item,
        ingress,
        &decided_at,
        existing_override,
    )
    .await?;
    // Reasserted for every ingress, not only `ProviderReconcile`: the
    // conflict check above only guards lane outcome, but a non-manual
    // override's *rank* still needs to track current priority ordering,
    // and automatic re-ranking is suppressed the whole time an override is
    // active. `triage_eligible` inside this call already leaves a terminal
    // exit dormant and never touches a Manual anchor's rank.
    let override_reapply_transition = Triage
        .reapply_active_override_outcome_in_tx(transaction, item, existing_override, &decided_at)
        .await?;
    let changed_placement = item.status != pre_triage_item.status
        || item.lane_position != pre_triage_item.lane_position
        || item.lane_origin != pre_triage_item.lane_origin
        || item.lane_set_at != pre_triage_item.lane_set_at;
    let transition_kind = override_reapply_transition.unwrap_or(if changed_placement {
        LaneTransitionKind::Automatic
    } else {
        LaneTransitionKind::Generic
    });
    Ok((outcome, transition_kind))
}

/// A direct human status move on the general item-update endpoint is never
/// itself a durable `Manual` lane anchor -- that explicit override control
/// is a separate feature -- but it still invalidates whatever `Automatic`
/// placement `BuiltInV1` previously recorded. Clearing that stale
/// provenance here (rather than suppressing placement while leaving the old
/// `Automatic` tag attached) keeps the item eligible for a fresh automatic
/// placement on its next eligible evaluation and stops the audit trail from
/// misattributing a human-chosen status to the evaluator. An existing
/// `Manual` anchor is left untouched. Pure item-struct bookkeeping, not a
/// triage evaluation, so it lives here rather than behind `TriageEvaluator`.
fn clear_stale_automatic_placement_on_human_status_move(
    before_status: TaskBoardStatus,
    item: &mut TaskBoardItem,
) {
    if before_status == item.status.canonical_persisted_status() {
        return;
    }
    let is_stale_automatic = item
        .lane_origin
        .as_ref()
        .is_some_and(|origin| !origin.is_manual());
    if is_stale_automatic {
        item.lane_position = None;
        item.lane_origin = None;
        item.lane_set_at = None;
    }
}

/// Decides the triage outcome for this write, applying an active triage's
/// placement effects when the ingress calls for it.
async fn compute_triage_outcome_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    before: &TaskBoardItem,
    item: &mut TaskBoardItem,
    ingress: TaskBoardTriageIngress,
    decided_at: &str,
    existing_override: Option<&TaskBoardTriageOverride>,
) -> Result<Option<TriageOutcome>, CliError> {
    match ingress {
        TaskBoardTriageIngress::None => Ok(None),
        TaskBoardTriageIngress::HumanUpdate | TaskBoardTriageIngress::ProviderReconcile => {
            let direct_effect_this_call = before.status != item.status
                || before.lane_position != item.lane_position
                || before.lane_origin != item.lane_origin;
            let suppress_placement =
                ingress == TaskBoardTriageIngress::HumanUpdate && direct_effect_this_call;
            Triage
                .apply_active_triage_in_tx(
                    transaction,
                    item,
                    decided_at,
                    suppress_placement,
                    existing_override,
                )
                .await
        }
    }
}

/// Rejects a human or internal-workflow write that lands the item in the
/// wrong triage lane, atomically -- silently reasserting instead would
/// discard the caller's intent. Only Inbox/Todo is in scope; a lifecycle
/// exit to Done etc. is always allowed and leaves the override dormant.
fn reject_if_conflicts_with_active_override(
    before: &TaskBoardItem,
    item: &TaskBoardItem,
    existing_override: Option<&TaskBoardTriageOverride>,
) -> Result<(), CliError> {
    let Some(existing_override) = existing_override else {
        return Ok(());
    };
    let requested_status = item.status.canonical_persisted_status();
    if requested_status == before.status.canonical_persisted_status() {
        return Ok(());
    }
    if !matches!(
        requested_status,
        TaskBoardStatus::Inbox | TaskBoardStatus::Todo
    ) {
        return Ok(());
    }
    if requested_status == Triage.override_implied_status(existing_override.verdict) {
        return Ok(());
    }
    Err(CliErrorKind::invalid_transition(
        "task-board item has an active triage override; change or clear the triage override instead of writing a conflicting status",
    )
    .into())
}
