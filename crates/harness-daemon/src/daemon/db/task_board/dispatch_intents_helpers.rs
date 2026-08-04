use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::admission_lifecycle::commit_compensating_dispatch_admission_in_tx;
use super::super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt;
use super::super::item_tx_ext::TaskBoardItemTxExt;
use super::super::items::bump_change_in_tx;
use super::super::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    DispatchAppliedTask, TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus,
};
use harness_policy_graph_store::restore_consumed_approval_grant_in_tx_at;

pub(in crate::daemon::db::task_board) async fn refuse_pending_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    applied: &DispatchAppliedTask,
    consumed_approval_grant_id: Option<&str>,
    reason: &str,
) -> Result<(), CliError> {
    prepare_pending_admission_refusal_in_tx(
        transaction,
        applied,
        consumed_approval_grant_id,
        reason,
    )
    .await?;
    let now = utc_now();
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'failed', last_error = ?2, completed_at = ?3, updated_at = ?3
         WHERE intent_id = ?1 AND status = 'pending'",
    )
    .bind(intent_id)
    .bind(reason)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("refuse task board worker admission: {error}")))?;
    transaction
        .release_dispatch_admission_in_tx(intent_id)
        .await?;
    Ok(())
}

/// Restores any consumed approval grant and rolls the linked item back to
/// `Todo` before the intent itself is marked failed.
async fn prepare_pending_admission_refusal_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    applied: &DispatchAppliedTask,
    consumed_approval_grant_id: Option<&str>,
    reason: &str,
) -> Result<(), CliError> {
    if let Some(grant_id) = consumed_approval_grant_id {
        restore_consumed_approval_grant_in_tx_at(transaction.as_mut(), grant_id, &utc_now())
            .await?;
    }
    let (item, revision) = transaction
        .load_item_in_tx(&applied.board_item_id)
        .await?
        .ok_or_else(|| {
            db_error(format!(
                "task-board item '{}' not found",
                applied.board_item_id
            ))
        })?;
    let still_linked = item.session_id.as_deref() == Some(applied.session_id.as_str())
        && item.work_item_id.as_deref() == Some(applied.work_item_id.as_str());
    if still_linked && dispatch_item_can_be_rolled_back(&item) {
        roll_back_dispatch_item_in_tx(transaction, item, revision, reason).await?;
    }
    Ok(())
}

pub(super) fn dispatch_item_can_be_rolled_back(item: &TaskBoardItem) -> bool {
    !item.is_deleted()
        && item.status == TaskBoardStatus::InProgress
        && item.workflow.status == TaskBoardWorkflowStatus::Running
}

/// Roll a refused item back to `Todo` and clear the dispatch it never got to
/// keep, recording the failure so the next look at the item explains itself.
async fn roll_back_dispatch_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    mut item: TaskBoardItem,
    revision: i64,
    reason: &str,
) -> Result<(), CliError> {
    let before = item.clone();
    item.workflow.status = TaskBoardWorkflowStatus::Failed;
    item.workflow.current_step_id = Some("admission".to_string());
    item.workflow.last_error = Some(reason.to_string());
    item.status = TaskBoardStatus::Todo;
    item.session_id = None;
    item.work_item_id = None;
    item.updated_at = utc_now();
    let write = replace_with_lane_transition_in_tx(
        transaction,
        before,
        revision,
        item,
        LaneTransitionKind::Generic,
    )
    .await?;
    let change_sequence = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    record_lane_transition_audit_in_tx(transaction, &write, change_sequence).await?;
    Ok(())
}

pub(in crate::daemon::db::task_board) async fn has_active_dispatch_reservation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_dispatch_intents
             WHERE item_id = ?1
               AND status IN (
                   'preparing', 'preparing_claimed', 'held', 'pending',
                   'workflow_prepared', 'starting'
               )
         )",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check task board dispatch reservation: {error}")))
}

/// Real implementations behind the matching [`DispatchAdmissionQueries`]
/// methods, called from the single consolidated trait impl in
/// `dispatch_admission_queries.rs` (a trait's methods can only be implemented
/// in one `impl` block per type, so the per-area files hand it plain
/// functions instead of each declaring their own `impl DispatchAdmissionQueries
/// for AsyncDaemonDb`).
pub(in crate::daemon::db::task_board) async fn begin_task_board_dispatch_compensation(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
    managed_worker_id: &str,
    reason: &str,
) -> Result<(), CliError> {
    if reason.is_empty() {
        return Err(db_error("task board dispatch compensation reason is empty"));
    }
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch compensation")
        .await?;
    let now = utc_now();
    let changed = query(
        "UPDATE task_board_dispatch_intents
         SET compensation_pending = 1, last_error = ?3,
             claimed_at = ?4, updated_at = ?4
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
           AND compensation_pending = 0",
    )
    .bind(intent_id)
    .bind(claim_token)
    .bind(reason)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("begin task board dispatch compensation: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(lost_claim(intent_id));
    }
    commit_compensating_dispatch_admission_in_tx(&mut transaction, intent_id, managed_worker_id)
        .await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit task board dispatch compensation marker: {error}"
        ))
    })
}

// The remaining `DispatchAdmissionQueries` real implementations live in
// `queries` (split into its own file to keep this one under the repo's line
// budget); they stay part of the `dispatch_intents::helpers` module.
#[path = "dispatch_intents_helpers_queries.rs"]
pub(in crate::daemon::db::task_board) mod queries;

async fn claimed_intent_identity(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
    compensation_pending: bool,
) -> Result<(String, String, String, String), CliError> {
    query_as::<_, (String, String, String, String)>(
        "SELECT item_id, session_id, work_item_id, workflow_execution_id
         FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
           AND compensation_pending = ?3",
    )
    .bind(intent_id)
    .bind(claim_token)
    .bind(compensation_pending)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load claimed task board dispatch: {error}")))?
    .ok_or_else(|| lost_claim(intent_id))
}

fn lost_claim(intent_id: &str) -> CliError {
    db_error(format!(
        "task board dispatch intent '{intent_id}' lost its claim"
    ))
}
