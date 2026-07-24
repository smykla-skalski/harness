use sqlx::{Sqlite, Transaction};

use super::ITEMS_CHANGE_SCOPE;
use super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::items::{
    apply_task_board_item_status_transition_in_tx, bump_change_in_tx,
    load_item_with_triage_override_in_tx,
};
use super::lane_order::{
    LaneTransitionKind, TaskBoardLanePositionAuditKind, TaskBoardLaneShift,
    record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use super::lane_order_audit::record_lane_position_audit_in_tx;
use super::triage_apply::{override_implied_status, reapply_active_override_outcome_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::errors::CliErrorKind;
use crate::task_board::{
    TaskBoardItem, TaskBoardLaneOrigin, TaskBoardStatus, TaskBoardTriageOverride,
    validate_lane_placement,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardLanePositionInput {
    pub(crate) item_id: String,
    pub(crate) status: Option<TaskBoardStatus>,
    pub(crate) lane_position: u32,
    pub(crate) actor: String,
    pub(crate) expected_item_revision: i64,
    pub(crate) expected_items_change_seq: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardLaneResetInput {
    pub(crate) item_id: String,
    pub(crate) actor: String,
    pub(crate) expected_item_revision: i64,
    pub(crate) expected_items_change_seq: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TaskBoardLaneMutationResult {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
    pub(crate) items_change_seq: i64,
    pub(crate) shifted: Vec<TaskBoardLaneShift>,
}

impl AsyncDaemonDb {
    /// Apply a manual absolute slot change under one item-list sequence CAS.
    pub(crate) async fn set_task_board_lane_position(
        &self,
        input: TaskBoardLanePositionInput,
    ) -> Result<TaskBoardLaneMutationResult, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board lane position")
            .await?;
        ensure_expected_sequence_in_tx(&mut transaction, input.expected_items_change_seq).await?;
        let (mut item, revision, existing_override) =
            load_item_with_triage_override_in_tx(&mut transaction, &input.item_id)
                .await?
                .ok_or_else(|| {
                    db_error(format!("task-board item '{}' not found", input.item_id))
                })?;
        ensure_expected_revision(&item.id, revision, input.expected_item_revision)?;
        if item.deleted_at.is_some() {
            return Err(
                CliErrorKind::invalid_transition("cannot place a deleted task-board item").into(),
            );
        }
        let requested_status = input
            .status
            .unwrap_or(item.status)
            .canonical_persisted_status();
        reject_if_destination_conflicts_with_active_override(
            item.status.canonical_persisted_status(),
            requested_status,
            existing_override.as_ref(),
        )?;
        let before = item.clone();
        let audit_before = before.clone();
        item.status = requested_status;
        item.lane_position = Some(input.lane_position);
        item.lane_origin = Some(TaskBoardLaneOrigin::Manual {
            actor: input.actor.clone(),
        });
        let now = utc_now();
        item.lane_set_at = Some(now.clone());
        item.updated_at = now;
        validate_lane_placement(&item).map_err(db_error)?;
        apply_task_board_item_status_transition_in_tx(&mut transaction, &item).await?;
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before,
            revision,
            item,
            LaneTransitionKind::Manual,
        )
        .await?;
        let items_change_seq = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_lane_position_audit_in_tx(
            &mut transaction,
            &audit_before,
            &write,
            items_change_seq,
            &input.actor,
            TaskBoardLanePositionAuditKind::Set,
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board lane position: {error}")))?;
        Ok(TaskBoardLaneMutationResult {
            item: write.item,
            item_revision: write.item_revision,
            items_change_seq,
            shifted: write.shifted,
        })
    }

    /// Reset an item to derived default ordering under one item-list sequence CAS.
    /// An active override reasserts through it -- reset means "return to
    /// override-derived ordering", not "fall to unranked default" -- unless a
    /// dispatch reservation is also active, in which case the reset is
    /// rejected atomically rather than clearing the anchor and leaving the
    /// reapply suppressed.
    pub(crate) async fn reset_task_board_lane_position(
        &self,
        input: TaskBoardLaneResetInput,
    ) -> Result<TaskBoardLaneMutationResult, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board lane reset")
            .await?;
        ensure_expected_sequence_in_tx(&mut transaction, input.expected_items_change_seq).await?;
        let (mut item, revision, existing_override) =
            load_item_with_triage_override_in_tx(&mut transaction, &input.item_id)
                .await?
                .ok_or_else(|| {
                    db_error(format!("task-board item '{}' not found", input.item_id))
                })?;
        ensure_expected_revision(&item.id, revision, input.expected_item_revision)?;
        if item.deleted_at.is_some() {
            return Err(
                CliErrorKind::invalid_transition("cannot reset a deleted task-board item").into(),
            );
        }
        if item.lane_position.is_none() {
            return Err(CliErrorKind::invalid_transition(
                "task-board item has no explicit position to reset",
            )
            .into());
        }
        if existing_override.is_some()
            && has_active_dispatch_reservation_in_tx(&mut transaction, &item.id).await?
        {
            return Err(CliErrorKind::invalid_transition(
                "task-board item has an active dispatch reservation; wait for it to clear before resetting an overridden item's position",
            )
            .into());
        }
        let before = item.clone();
        let audit_before = before.clone();
        clear_placement(&mut item);
        let now = utc_now();
        item.updated_at = now.clone();
        let override_reapply_transition = reapply_active_override_outcome_in_tx(
            &mut transaction,
            &mut item,
            existing_override.as_ref(),
            &now,
        )
        .await?;
        let transition = override_reapply_transition.unwrap_or(LaneTransitionKind::Generic);
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before,
            revision,
            item,
            transition,
        )
        .await?;
        let items_change_seq = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_lane_position_audit_in_tx(
            &mut transaction,
            &audit_before,
            &write,
            items_change_seq,
            &input.actor,
            TaskBoardLanePositionAuditKind::Reset,
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board lane reset: {error}")))?;
        Ok(TaskBoardLaneMutationResult {
            item: write.item,
            item_revision: write.item_revision,
            items_change_seq,
            shifted: write.shifted,
        })
    }

    /// Later automation can use this internal seam without replacing manual
    /// anchors or an active override's lane/provenance -- the latter is the
    /// override choke point's job to reassert, not arbitrary automation's.
    pub(crate) async fn place_task_board_item_automatically(
        &self,
        item_id: &str,
        lane_position: u32,
        producer: String,
    ) -> Result<Option<TaskBoardLaneMutationResult>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automatic lane position")
            .await?;
        let (mut item, revision, existing_override) =
            load_item_with_triage_override_in_tx(&mut transaction, item_id)
                .await?
                .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        let before = item.clone();
        let manually_placed = before
            .lane_origin
            .as_ref()
            .is_some_and(TaskBoardLaneOrigin::is_manual);
        if manually_placed || existing_override.is_some() {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit preserved existing lane placement: {error}"))
            })?;
            return Ok(None);
        }
        item.lane_position = Some(lane_position);
        item.lane_origin = Some(TaskBoardLaneOrigin::Automatic { producer });
        let now = utc_now();
        item.lane_set_at = Some(now.clone());
        item.updated_at = now;
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before,
            revision,
            item,
            LaneTransitionKind::Automatic,
        )
        .await?;
        let items_change_seq = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_lane_transition_audit_in_tx(&mut transaction, &write, items_change_seq).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit automatic lane position: {error}")))?;
        Ok(Some(TaskBoardLaneMutationResult {
            item: write.item,
            item_revision: write.item_revision,
            items_change_seq,
            shifted: write.shifted,
        }))
    }
}

async fn ensure_expected_sequence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: i64,
) -> Result<(), CliError> {
    let actual = sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = ?1",
    )
    .bind(ITEMS_CHANGE_SCOPE)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read task-board lane sequence: {error}")))?
    .unwrap_or(0);
    if actual == expected {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(format!(
        "task-board item sequence changed from {expected} to {actual}"
    ))
    .into())
}

fn ensure_expected_revision(item_id: &str, actual: i64, expected: i64) -> Result<(), CliError> {
    if actual == expected {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(format!(
        "task-board item '{item_id}' revision changed from {expected} to {actual}"
    ))
    .into())
}

/// A manual position write between Backlog and Todo that conflicts with an
/// active override is rejected atomically. Lifecycle exits remain allowed
/// because the override becomes dormant outside those triage lanes.
fn reject_if_destination_conflicts_with_active_override(
    current_status: TaskBoardStatus,
    requested_status: TaskBoardStatus,
    existing_override: Option<&TaskBoardTriageOverride>,
) -> Result<(), CliError> {
    if requested_status == current_status
        || !matches!(
            requested_status,
            TaskBoardStatus::Backlog | TaskBoardStatus::Todo
        )
    {
        return Ok(());
    }
    let Some(existing_override) = existing_override else {
        return Ok(());
    };
    if requested_status == override_implied_status(existing_override.verdict) {
        return Ok(());
    }
    Err(CliErrorKind::invalid_transition(
        "task-board item has an active triage override; change or clear the triage override instead of moving it to a conflicting lane",
    )
    .into())
}

fn clear_placement(item: &mut TaskBoardItem) {
    item.lane_position = None;
    item.lane_origin = None;
    item.lane_set_at = None;
}
