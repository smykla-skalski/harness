//! Real implementations behind the matching
//! [`super::super::dispatch_admission_queries::DispatchAdmissionQueries`]
//! methods, called from the single consolidated trait impl in
//! `dispatch_admission_queries.rs` (a trait's methods can only be implemented
//! in one `impl` block per type, so the per-area files hand it plain
//! functions instead of each declaring their own `impl DispatchAdmissionQueries
//! for AsyncDaemonDb`). Split out of `dispatch_preparations.rs` to keep that
//! file under the repo's line budget; these functions stay part of the
//! `dispatch_preparations` module, not a separate area. `reserve_task_board_dispatch`
//! stays in the parent file because it is the entry point every reader looks
//! for first.

use sqlx::{query, query_as};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt;
use super::super::dispatch_preparation_claim::TaskBoardPreparationClaim;
use super::super::dispatch_workflow_launch::prepare_workflow_launches_for_publication;
use super::super::items::{bump_change_in_tx, load_item_in_tx};
use super::super::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use super::helpers::{
    PREPARATION_MAX_ATTEMPTS, PreparationClaim, apply_preparation_to_item,
    claim_preparation_intent_in_tx, claimed_attempts_in_tx, commit_preparation,
    ensure_preparation_claim, fail_preparation_admission_in_tx, preparation_retry_delay_seconds,
    rearm_preparation_in_tx, screen_preparation_claim_in_tx, validate_reservable_item,
};
use super::{
    ClaimedTaskBoardDispatchPreparation, PREPARATION_LEASE_SECONDS, TaskBoardPreparationRelease,
    consume_prepared_approval_grant, rebind_prepared_workflow_launches,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{DispatchAppliedTask, TaskBoardReadOnlyWorkflowLaunch, TaskBoardWriteWorkflowLaunch};
use harness_kernel::errors::CliErrorKind;

pub(in crate::daemon::db::task_board) async fn attempt_task_board_dispatch_preparation_claim(
    db: &AsyncDaemonDb,
    intent_id: &str,
) -> Result<TaskBoardPreparationClaim, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch preparation claim")
        .await?;
    let preparation = match screen_preparation_claim_in_tx(&mut transaction, intent_id).await? {
        PreparationClaim::Ready(preparation) => *preparation,
        PreparationClaim::Unavailable(reason) => {
            commit_preparation(transaction, "unclaimable task board preparation").await?;
            return Ok(TaskBoardPreparationClaim::Unavailable(reason));
        }
        PreparationClaim::Refused { context, reason } => {
            commit_preparation(transaction, context).await?;
            return Err(CliErrorKind::invalid_transition(reason).into());
        }
    };
    let claim_token = claim_preparation_intent_in_tx(&mut transaction, intent_id).await?;
    commit_preparation(transaction, "task board preparation claim").await?;
    Ok(TaskBoardPreparationClaim::Claimed(Box::new(
        ClaimedTaskBoardDispatchPreparation {
            intent_id: intent_id.to_string(),
            claim_token,
            preparation,
        },
    )))
}

pub(in crate::daemon::db::task_board) async fn claim_task_board_dispatch_preparation(
    db: &AsyncDaemonDb,
    intent_id: &str,
) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
    Ok(attempt_task_board_dispatch_preparation_claim(db, intent_id)
        .await?
        .claimed())
}

pub(in crate::daemon::db::task_board) async fn claim_next_task_board_dispatch_preparation(
    db: &AsyncDaemonDb,
) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
    let intent_id = query_as::<_, (String,)>(
        "SELECT intent_id FROM task_board_dispatch_intents
             WHERE (status = 'preparing' AND datetime(available_at) <= datetime('now'))
                OR (status = 'preparing_claimed'
                    AND datetime(claimed_at) <= datetime('now', ?1))
             ORDER BY created_at, intent_id LIMIT 1",
    )
    .bind(format!("-{PREPARATION_LEASE_SECONDS} seconds"))
    .fetch_optional(db.pool())
    .await
    .map_err(|error| db_error(format!("load next task board preparation: {error}")))?
    .map(|row| row.0);
    match intent_id {
        Some(intent_id) => claim_task_board_dispatch_preparation(db, &intent_id).await,
        None => Ok(None),
    }
}

pub(in crate::daemon::db::task_board) async fn renew_task_board_dispatch_preparation(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch preparation renewal")
        .await?;
    let changed = query(
        "UPDATE task_board_dispatch_intents
             SET claimed_at = ?3, updated_at = ?3
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
    )
    .bind(&claim.intent_id)
    .bind(&claim.claim_token)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("renew task board preparation: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(db_error(format!(
            "task board preparation '{}' lost its claim",
            claim.intent_id
        )));
    }
    transaction
        .renew_dispatch_admission_in_tx(&claim.intent_id)
        .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board preparation renewal: {error}")))
}

pub(in crate::daemon::db::task_board) async fn complete_task_board_dispatch_preparation(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
    branch: &str,
    worktree: &str,
) -> Result<DispatchAppliedTask, CliError> {
    complete_task_board_dispatch_preparation_with_workflow(db, claim, branch, worktree, None, None)
        .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "dispatch completion must keep item linking and intent publication atomic"
)]
pub(in crate::daemon::db::task_board) async fn complete_task_board_dispatch_preparation_with_workflow(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
    branch: &str,
    worktree: &str,
    mut read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
    mut write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
) -> Result<DispatchAppliedTask, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch preparation completion")
        .await?;
    ensure_preparation_claim(&mut transaction, claim).await?;
    let preparation = &claim.preparation;
    let (mut item, revision) = load_item_in_tx(&mut transaction, &preparation.board_item_id)
        .await?
        .ok_or_else(|| {
            db_error(format!(
                "task-board item '{}' not found",
                preparation.board_item_id
            ))
        })?;
    let before = item.clone();
    validate_reservable_item(&item, &preparation.plan)?;
    (read_only_workflow, write_workflow) = prepare_workflow_launches_for_publication(
        preparation,
        &item,
        revision,
        worktree,
        read_only_workflow,
        write_workflow,
    )?;
    apply_preparation_to_item(&mut item, preparation, branch, worktree);
    let write = replace_with_lane_transition_in_tx(
        &mut transaction,
        before,
        revision,
        item,
        LaneTransitionKind::Generic,
    )
    .await?;
    let prepared_item_revision = write.item_revision;
    let item = write.item.clone();
    rebind_prepared_workflow_launches(
        &item,
        prepared_item_revision,
        &preparation.workflow_execution_id,
        &mut read_only_workflow,
        &mut write_workflow,
    )?;
    consume_prepared_approval_grant(&mut transaction, preparation).await?;
    let applied = DispatchAppliedTask {
        board_item_id: preparation.board_item_id.clone(),
        session_id: preparation.session_id.clone(),
        work_item_id: preparation.work_item_id.clone(),
        lifecycle: preparation.plan.applied_lifecycle(),
        item,
        read_only_workflow,
        write_workflow,
    };
    let payload = serde_json::to_string(&applied)
        .map_err(|error| db_error(format!("serialize prepared task board dispatch: {error}")))?;
    let published_status = if preparation.hold_worker {
        "held"
    } else {
        "pending"
    };
    query(
        "UPDATE task_board_dispatch_intents
             SET payload_json = ?3, status = ?4, claim_token = NULL,
                 claimed_at = NULL, last_error = NULL, updated_at = ?5,
                 consumed_approval_grant_id = ?6
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
    )
    .bind(&claim.intent_id)
    .bind(&claim.claim_token)
    .bind(payload)
    .bind(published_status)
    .bind(utc_now())
    .bind(if preparation.hold_worker {
        None
    } else {
        preparation.plan.consumed_approval_grant_id.as_deref()
    })
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("complete task board preparation: {error}")))?;
    let change_sequence = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
    record_lane_transition_audit_in_tx(&mut transaction, &write, change_sequence).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board preparation completion: {error}")))?;
    Ok(applied)
}

pub(in crate::daemon::db::task_board) async fn release_task_board_dispatch_preparation(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
    reason: &str,
) -> Result<TaskBoardPreparationRelease, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch preparation release")
        .await?;
    let attempts = claimed_attempts_in_tx(&mut transaction, claim).await?;
    if attempts >= PREPARATION_MAX_ATTEMPTS {
        // Retiring the intent clears the Admitting stamp inside
        // `fail_preparation_admission_in_tx`, so the ticket drops back to
        // Idle and a fresh dispatch mints a new execution instead of finding
        // a dead one.
        fail_preparation_admission_in_tx(&mut transaction, &claim.intent_id, reason).await?;
        commit_preparation(transaction, "task board preparation give-up").await?;
        return Ok(TaskBoardPreparationRelease::GaveUp { attempts });
    }
    let delay_seconds = preparation_retry_delay_seconds(attempts);
    rearm_preparation_in_tx(&mut transaction, claim, reason, delay_seconds).await?;
    commit_preparation(transaction, "task board preparation release").await?;
    Ok(TaskBoardPreparationRelease::Retrying { delay_seconds })
}
