//! Completion of a claimed dispatch intent: the screen that proves the claim
//! still owns its item, the write that starts the workflow, and the intent
//! settlement. The caller in `dispatch_intents.rs` owns the transaction and
//! commits once.

use sqlx::{Sqlite, Transaction, query};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::admission_lifecycle::{
    commit_dispatch_admission_in_tx, validate_worker_start_fence_in_tx,
};
use super::super::dispatch_workflow_start::{
    insert_started_workflow_in_tx, load_claimed_applied, workflow_start_fence,
};
use super::super::items::{bump_change_in_tx, load_item_in_tx};
use super::super::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use super::{claimed_intent_identity, ensure_dispatch_item_startable};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{DispatchAppliedTask, TaskBoardItem, TaskBoardWorkflowStatus};

/// A claimed intent whose item, revision and payload have all been proven to
/// still match each other.
pub(super) struct ScreenedDispatchCompletion {
    item: TaskBoardItem,
    revision: i64,
    applied: DispatchAppliedTask,
}

/// Proves the claimed intent still owns the item it was created for, that the
/// item is startable, and that any prepared-workflow fence still holds.
/// Writes nothing, so a failure here rolls the whole completion back.
pub(super) async fn screen_dispatch_completion_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<Box<ScreenedDispatchCompletion>, CliError> {
    let (item_id, session_id, work_item_id, execution_id) =
        claimed_intent_identity(transaction, intent_id, claim_token).await?;
    let applied = load_claimed_applied(transaction, intent_id, claim_token).await?;
    let (item, revision) = load_item_in_tx(transaction, &item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    let still_linked = item.session_id.as_deref() == Some(session_id.as_str())
        && item.work_item_id.as_deref() == Some(work_item_id.as_str())
        && item.workflow.execution_id.as_deref() == Some(execution_id.as_str());
    if !still_linked {
        return Err(db_error(format!(
            "task board dispatch intent '{intent_id}' no longer matches its item linkage"
        )));
    }
    validate_dispatch_start_fence_in_tx(transaction, &applied, revision).await?;
    ensure_dispatch_item_startable(&item, &session_id, &work_item_id, Some(&execution_id))?;
    Ok(Box::new(ScreenedDispatchCompletion {
        item,
        revision,
        applied,
    }))
}

/// A dispatch whose workflow was prepared carries the item and configuration
/// revisions it was prepared against; an unprepared one has no fence to hold.
async fn validate_dispatch_start_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    applied: &DispatchAppliedTask,
    revision: i64,
) -> Result<(), CliError> {
    if let Some((prepared_item_revision, configuration_revision)) = workflow_start_fence(applied)? {
        validate_worker_start_fence_in_tx(
            transaction,
            Some((prepared_item_revision, configuration_revision)),
            revision,
        )
        .await?;
    }
    Ok(())
}

/// Moves the screened item to a running worker, inserts its started workflow
/// row and audits the lane transition. Returns the stored item.
pub(super) async fn apply_dispatch_completion_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    screened: ScreenedDispatchCompletion,
    intent_id: &str,
) -> Result<TaskBoardItem, CliError> {
    let ScreenedDispatchCompletion {
        mut item,
        revision,
        applied,
    } = screened;
    let before = item.clone();
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("worker_running".to_string());
    item.workflow.last_error = None;
    item.updated_at = utc_now();
    let write = replace_with_lane_transition_in_tx(
        transaction,
        before,
        revision,
        item,
        LaneTransitionKind::Generic,
    )
    .await?;
    let item = write.item.clone();
    insert_started_workflow_in_tx(transaction, &item, write.item_revision, intent_id, &applied)
        .await?;
    let change_sequence = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    record_lane_transition_audit_in_tx(transaction, &write, change_sequence).await?;
    Ok(item)
}

/// Marks the intent completed and hands its admission to the started worker.
/// The `UPDATE` re-checks the claim, so a claim that expired or was
/// compensated between the screen and here changes no row and fails.
pub(super) async fn settle_dispatch_intent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
    managed_worker_id: &str,
) -> Result<(), CliError> {
    let changed = query(
        "UPDATE task_board_dispatch_intents SET status = 'completed', last_error = NULL,
         claim_token = NULL, claimed_at = NULL, updated_at = ?3, completed_at = ?3
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
           AND compensation_pending = 0",
    )
    .bind(intent_id)
    .bind(claim_token)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("complete task board dispatch intent: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(db_error(format!(
            "task board dispatch intent '{intent_id}' is not claimed"
        )));
    }
    commit_dispatch_admission_in_tx(transaction, intent_id, managed_worker_id).await
}
