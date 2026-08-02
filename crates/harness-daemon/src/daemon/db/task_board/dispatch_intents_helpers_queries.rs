//! Real implementations behind the matching
//! [`super::super::super::dispatch_admission_queries::DispatchAdmissionQueries`]
//! methods, called from the single consolidated trait impl in
//! `dispatch_admission_queries.rs` (a trait's methods can only be implemented
//! in one `impl` block per type, so the per-area files hand it plain
//! functions instead of each declaring their own `impl DispatchAdmissionQueries
//! for AsyncDaemonDb`). Split out of `dispatch_intents_helpers.rs` to keep
//! that file under the repo's line budget; these functions stay part of the
//! `dispatch_intents::helpers` module, not a separate area.

use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::super::super::ITEMS_CHANGE_SCOPE;
use super::super::super::admission_lifecycle::finalize_compensating_dispatch_admission_in_tx;
use super::super::super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt;
use super::super::super::item_tx_ext::TaskBoardItemTxExt;
use super::super::super::items::bump_change_in_tx;
use super::super::super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, record_lane_transition_audit_in_tx,
    replace_with_lane_transition_in_tx,
};
use super::{claimed_intent_identity, dispatch_item_can_be_rolled_back, lost_claim};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{DispatchAppliedTask, TaskBoardStatus, TaskBoardWorkflowStatus};
use harness_policy_graph_store::restore_consumed_approval_grant_in_tx_at;
use crate::daemon::db::prelude::*;

pub(in crate::daemon::db::task_board) async fn task_board_dispatch_is_completed(
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
) -> Result<bool, CliError> {
    task_board_dispatch_has_status(db, applied, "completed").await
}

pub(in crate::daemon::db::task_board) async fn task_board_dispatch_completion_matches(
    db: &AsyncDaemonDb,
    intent_id: &str,
    execution_id: &str,
    managed_worker_id: &str,
    admission_owner_id: &str,
    side_effect_worker_id: &str,
    require_workflow_evidence: bool,
) -> Result<bool, CliError> {
    let intent_matches = query_scalar::<_, bool>(
        "SELECT EXISTS(
                 SELECT 1 FROM task_board_dispatch_intents AS intent
                 WHERE intent.intent_id = ?1 AND intent.workflow_execution_id = ?2
                   AND intent.status = 'completed'
                   AND COALESCE((
                       SELECT json_array_length(decision.requirements_json)
                       FROM task_board_dispatch_admission_decisions AS decision
                       WHERE decision.intent_id = intent.intent_id
                         AND decision.is_current = 1 AND decision.decision = 'allowed'
                   ), 0) = (
                       SELECT COUNT(*) FROM task_board_dispatch_admission_ledger AS ledger
                       WHERE ledger.intent_id = intent.intent_id
                         AND ledger.committed_at IS NOT NULL
                         AND ledger.managed_worker_id = ?3
                   )
                   AND NOT EXISTS(
                       SELECT 1 FROM task_board_dispatch_admission_ledger AS ledger
                       WHERE ledger.intent_id = intent.intent_id
                         AND ledger.committed_at IS NOT NULL
                         AND (ledger.managed_worker_id IS NULL
                              OR ledger.managed_worker_id != ?3)
                   )
             )",
    )
    .bind(intent_id)
    .bind(execution_id)
    .bind(managed_worker_id)
    .fetch_one(db.pool())
    .await
    .map_err(|error| {
        db_error(format!(
            "check exact task board dispatch completion: {error}"
        ))
    })?;
    if !intent_matches || !require_workflow_evidence {
        return Ok(intent_matches);
    }
    query_scalar::<_, bool>(
        "SELECT EXISTS(
                 SELECT 1 FROM task_board_workflow_executions AS execution
                 WHERE execution.execution_id = ?1
                   AND json_extract(execution.resource_ownership_json,
                                    '$.resources.admission_owner') = ?2
                   AND EXISTS(
                       SELECT 1 FROM task_board_execution_attempts AS attempt
                       WHERE attempt.execution_id = execution.execution_id
                         AND attempt.idempotency_key = ?3
                   )
             )",
    )
    .bind(execution_id)
    .bind(admission_owner_id)
    .bind(side_effect_worker_id)
    .fetch_one(db.pool())
    .await
    .map_err(|error| {
        db_error(format!(
            "check exact task board workflow completion evidence: {error}"
        ))
    })
}

pub(in crate::daemon::db::task_board) async fn task_board_dispatch_is_held(
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
) -> Result<bool, CliError> {
    task_board_dispatch_has_status(db, applied, "held").await
}

async fn task_board_dispatch_has_status(
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
    status: &str,
) -> Result<bool, CliError> {
    let Some(execution_id) = applied.item.workflow.execution_id.as_deref() else {
        return Ok(false);
    };
    query_scalar::<_, bool>(
        "SELECT EXISTS(
                 SELECT 1 FROM task_board_dispatch_intents
                 WHERE item_id = ?1 AND session_id = ?2 AND work_item_id = ?3
                   AND workflow_execution_id = ?4 AND status = ?5
             )",
    )
    .bind(&applied.board_item_id)
    .bind(&applied.session_id)
    .bind(&applied.work_item_id)
    .bind(execution_id)
    .bind(status)
    .fetch_one(db.pool())
    .await
    .map_err(|error| db_error(format!("check task board dispatch status: {error}")))
}

pub(in crate::daemon::db::task_board) async fn renew_task_board_dispatch_claim(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
) -> Result<(), CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch claim renewal")
        .await?;
    let compensation_pending = query_scalar::<_, bool>(
        "SELECT compensation_pending FROM task_board_dispatch_intents
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'",
    )
    .bind(intent_id)
    .bind(claim_token)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board dispatch claim: {error}")))?
    .ok_or_else(|| lost_claim(intent_id))?;
    let changed = query(
        "UPDATE task_board_dispatch_intents
             SET claimed_at = ?3, updated_at = ?3
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'",
    )
    .bind(intent_id)
    .bind(claim_token)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("renew task board dispatch claim: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(lost_claim(intent_id));
    }
    if !compensation_pending {
        transaction
            .renew_frozen_dispatch_admission_in_tx(intent_id)
            .await?;
    }
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board dispatch renewal: {error}")))
}

pub(in crate::daemon::db::task_board) async fn fail_task_board_dispatch(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
    consumed_approval_grant_id: Option<&str>,
    reason: &str,
) -> Result<(), CliError> {
    finish_failed_task_board_dispatch(
        db,
        intent_id,
        claim_token,
        consumed_approval_grant_id,
        None,
        reason,
        false,
    )
    .await
}

pub(in crate::daemon::db::task_board) async fn finalize_task_board_dispatch_compensation(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
    managed_worker_id: &str,
    reason: &str,
) -> Result<(), CliError> {
    finish_failed_task_board_dispatch(
        db,
        intent_id,
        claim_token,
        None,
        Some(managed_worker_id),
        reason,
        true,
    )
    .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "dispatch failure keeps item rollback and intent completion atomic"
)]
async fn finish_failed_task_board_dispatch(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
    consumed_approval_grant_id: Option<&str>,
    managed_worker_id: Option<&str>,
    reason: &str,
    expected_compensation: bool,
) -> Result<(), CliError> {
    let mut transaction: Transaction<'_, Sqlite> = db
        .begin_immediate_transaction("task board dispatch failure")
        .await?;
    let (item_id, session_id, work_item_id, execution_id) = claimed_intent_identity(
        &mut transaction,
        intent_id,
        claim_token,
        expected_compensation,
    )
    .await?;
    if let Some(grant_id) = consumed_approval_grant_id {
        restore_consumed_approval_grant_in_tx_at(transaction.as_mut(), grant_id, &utc_now())
            .await?;
    }
    let (mut item, revision) = transaction
        .load_item_in_tx(&item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    let still_linked = item.session_id.as_deref() == Some(session_id.as_str())
        && item.work_item_id.as_deref() == Some(work_item_id.as_str())
        && item.workflow.execution_id.as_deref() == Some(execution_id.as_str());
    let mut lane_write: Option<LaneTransitionWrite> = None;
    if still_linked && dispatch_item_can_be_rolled_back(&item) {
        let before = item.clone();
        item.workflow.status = TaskBoardWorkflowStatus::Failed;
        item.workflow.current_step_id = Some("worker_spawn".to_string());
        item.workflow.last_error = Some(reason.to_string());
        item.status = TaskBoardStatus::Todo;
        item.session_id = None;
        item.work_item_id = None;
        item.updated_at = utc_now();
        lane_write = Some(
            replace_with_lane_transition_in_tx(
                &mut transaction,
                before,
                revision,
                item,
                LaneTransitionKind::Generic,
            )
            .await?,
        );
    }
    let now = utc_now();
    let changed = query(
        "UPDATE task_board_dispatch_intents
             SET status = 'failed', last_error = ?3, compensation_pending = 0,
                 claim_token = NULL, claimed_at = NULL, updated_at = ?4, completed_at = ?4
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
               AND compensation_pending = ?5",
    )
    .bind(intent_id)
    .bind(claim_token)
    .bind(reason)
    .bind(now)
    .bind(expected_compensation)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("fail task board dispatch: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(lost_claim(intent_id));
    }
    let admission_changed = if let Some(managed_worker_id) = managed_worker_id {
        finalize_compensating_dispatch_admission_in_tx(
            &mut transaction,
            intent_id,
            managed_worker_id,
        )
        .await?
    } else {
        transaction
            .release_dispatch_admission_in_tx(intent_id)
            .await?;
        false
    };
    if lane_write.is_some() || admission_changed {
        let change_sequence = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        if let Some(write) = lane_write.as_ref() {
            record_lane_transition_audit_in_tx(&mut transaction, write, change_sequence).await?;
        }
    }
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board dispatch failure: {error}")))
}
