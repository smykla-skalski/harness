use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::super::admission_lifecycle::{
    TaskBoardAdmissionCheck, release_dispatch_admission_in_tx, revalidate_dispatch_admission_in_tx,
};
use super::super::dispatch_preparation_claim::{
    TaskBoardPreparationUnavailable, classify_unavailable_preparation_in_tx,
};
use super::super::items::load_item_in_tx;
use super::{
    ClaimedTaskBoardDispatchPreparation, PREPARATION_LEASE_SECONDS, ReservedTaskBoardDispatch,
    TaskBoardDispatchPreparation, preparation_revision_error,
};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::session::types::TaskSeverity;
use crate::task_board::{
    DispatchPlan, SessionIntent, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TaskBoardWorkflowStatus,
};

/// Claimed attempts a preparation gets before the board stops retrying it.
pub(crate) const PREPARATION_MAX_ATTEMPTS: i64 = 8;

/// Longest gap between attempts. Bounds the doubling below so a failure that
/// heals on its own is still picked up in reasonable time.
const PREPARATION_RETRY_CAP_SECONDS: i64 = 300;

/// Doubles the wait after every failed attempt. A preparation that cannot
/// succeed otherwise costs a full claim every second for as long as the daemon
/// runs, which is how one reached 26,000 attempts in 13 hours.
pub(super) fn preparation_retry_delay_seconds(attempts: i64) -> i64 {
    let doublings = attempts.max(1) - 1;
    if doublings >= i64::BITS.into() {
        return PREPARATION_RETRY_CAP_SECONDS;
    }
    u32::try_from(doublings)
        .ok()
        .and_then(|doublings| 1i64.checked_shl(doublings))
        .filter(|delay| delay.is_positive())
        .unwrap_or(PREPARATION_RETRY_CAP_SECONDS)
        .min(PREPARATION_RETRY_CAP_SECONDS)
}

/// Attempts recorded against a claim, or an error when the claim no longer holds.
pub(super) async fn claimed_attempts_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<i64, CliError> {
    query_as::<_, (i64,)>(
        "SELECT attempts FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
    )
    .bind(&claim.intent_id)
    .bind(&claim.claim_token)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board preparation attempts: {error}")))?
    .map(|row| row.0)
    .ok_or_else(|| {
        db_error(format!(
            "task board preparation '{}' is not claimed",
            claim.intent_id
        ))
    })
}

/// Returns the claim to the queue, invisible until `delay_seconds` have passed.
pub(super) async fn rearm_preparation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    claim: &ClaimedTaskBoardDispatchPreparation,
    reason: &str,
    delay_seconds: i64,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'preparing', claim_token = NULL, claimed_at = NULL,
             last_error = ?3, available_at = datetime('now', ?4), updated_at = ?5
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
    )
    .bind(&claim.intent_id)
    .bind(&claim.claim_token)
    .bind(reason)
    .bind(format!("+{delay_seconds} seconds"))
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release task board preparation: {error}")))?;
    Ok(())
}

pub(super) fn apply_preparation_to_item(
    item: &mut TaskBoardItem,
    preparation: &TaskBoardDispatchPreparation,
    branch: &str,
    worktree: &str,
) {
    item.workflow.execution_id = Some(preparation.workflow_execution_id.clone());
    item.workflow.branch = Some(branch.to_string());
    item.workflow.worktree = Some(worktree.to_string());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some(
        if preparation.hold_worker {
            "awaiting_delivery"
        } else {
            "dispatch"
        }
        .to_string(),
    );
    item.workflow.attempts = item.workflow.attempts.saturating_add(1);
    // Record the real recorded-decision id from evaluation so the workflow
    // trace correlates with the decision feed. Fall back to a minted trace id
    // only when the built-in fallback gate decided (no recorded id).
    item.workflow.push_policy_trace_id(
        preparation
            .plan
            .policy_decision_id
            .clone()
            .unwrap_or_else(|| format!("policy-trace-{}", Uuid::new_v4().simple())),
    );
    item.status = TaskBoardStatus::InProgress;
    item.session_id = Some(preparation.session_id.clone());
    item.work_item_id = Some(preparation.work_item_id.clone());
    item.updated_at = utc_now();
}

pub(super) async fn fail_preparation_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    reason: &str,
) -> Result<(), CliError> {
    let now = utc_now();
    // Clearing the claim is not optional: a row leaving 'preparing_claimed'
    // still holding a token violates the table's status/claim CHECK, and this
    // statement accepts claimed rows.
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'failed', claim_token = NULL, claimed_at = NULL,
             last_error = ?2, completed_at = ?3, updated_at = ?3
         WHERE intent_id = ?1 AND status IN ('preparing', 'preparing_claimed')",
    )
    .bind(intent_id)
    .bind(reason)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("refuse task board preparation admission: {error}")))?;
    release_dispatch_admission_in_tx(transaction, intent_id).await?;
    Ok(())
}

pub(super) async fn active_reservation(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<ReservedTaskBoardDispatch>, CliError> {
    let row = query_as::<_, (String, String, String)>(
        "SELECT intent_id, status, payload_json FROM task_board_dispatch_intents
         WHERE item_id = ?1
           AND status IN (
               'preparing', 'preparing_claimed', 'held', 'pending', 'starting',
               'workflow_prepared'
           )
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load active task board reservation: {error}")))?;
    row.map(|(intent_id, status, payload)| {
        if matches!(status.as_str(), "preparing" | "preparing_claimed") {
            Ok(ReservedTaskBoardDispatch::Preparing {
                intent_id,
                preparation: Box::new(decode_preparation(&payload)?),
            })
        } else {
            serde_json::from_str(&payload)
                .map(Box::new)
                .map(ReservedTaskBoardDispatch::Applied)
                .map_err(|error| db_error(format!("decode active task board dispatch: {error}")))
        }
    })
    .transpose()
}

pub(super) async fn insert_preparation(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    preparation: &TaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    let payload = serde_json::to_string(preparation)
        .map_err(|error| db_error(format!("serialize task board preparation: {error}")))?;
    let now = utc_now();
    query(
        "INSERT INTO task_board_dispatch_intents (
            intent_id, item_id, session_id, work_item_id, workflow_execution_id, payload_json,
            status, attempts, available_at, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'preparing', 0, ?7, ?7, ?7)",
    )
    .bind(intent_id)
    .bind(&preparation.board_item_id)
    .bind(&preparation.session_id)
    .bind(&preparation.work_item_id)
    .bind(&preparation.workflow_execution_id)
    .bind(payload)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task board preparation: {error}")))?;
    Ok(())
}

pub(super) async fn release_expired_preparations(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'preparing', claim_token = NULL, claimed_at = NULL, updated_at = ?1
         WHERE status = 'preparing_claimed'
           AND datetime(claimed_at) <= datetime('now', ?2)",
    )
    .bind(utc_now())
    .bind(format!("-{PREPARATION_LEASE_SECONDS} seconds"))
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release expired task board preparations: {error}")))?;
    Ok(())
}

pub(super) async fn ensure_preparation_claim(
    transaction: &mut Transaction<'_, Sqlite>,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    let exists = query_as::<_, (i64,)>(
        "SELECT COUNT(*) FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
    )
    .bind(&claim.intent_id)
    .bind(&claim.claim_token)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify task board preparation claim: {error}")))?
    .0;
    if exists == 1 {
        Ok(())
    } else {
        Err(db_error(format!(
            "task board preparation '{}' is not claimed",
            claim.intent_id
        )))
    }
}

pub(super) fn validate_reservable_item(
    item: &TaskBoardItem,
    plan: &DispatchPlan,
) -> Result<(), CliError> {
    let body = item.body.trim();
    let body = (!body.is_empty()).then_some(body);
    let session_matches = match &plan.session {
        SessionIntent::Existing { session_id } => item.session_id.as_deref() == Some(session_id),
        SessionIntent::Create { .. } => item.session_id.is_none(),
    };
    let matches_plan = item.id == plan.board_item_id
        && item.title == plan.task.title
        && body == plan.task.context.as_deref()
        && dispatch_severity(item.priority) == plan.task.severity
        && item.planning.summary == plan.task.suggested_fix
        && item.tags == plan.task.tags
        && item.external_refs == plan.task.external_refs
        && item.status == TaskBoardStatus::Todo
        && session_matches
        && item.work_item_id.is_none()
        && !item.is_deleted();
    if matches_plan {
        Ok(())
    } else {
        Err(db_error(format!(
            "task-board item '{}' changed before dispatch reservation",
            plan.board_item_id
        )))
    }
}

const fn dispatch_severity(priority: TaskBoardPriority) -> TaskSeverity {
    match priority {
        TaskBoardPriority::Low => TaskSeverity::Low,
        TaskBoardPriority::Medium => TaskSeverity::Medium,
        TaskBoardPriority::High => TaskSeverity::High,
        TaskBoardPriority::Critical => TaskSeverity::Critical,
    }
}

/// What the preparation-claim screen decided. Both settled variants name the
/// commit's error context; `Refused` is the one the caller turns into an error,
/// because the screen recorded the preparation as failed on its way out.
pub(super) enum PreparationClaim {
    Ready(Box<TaskBoardDispatchPreparation>),
    Unavailable(TaskBoardPreparationUnavailable),
    Refused {
        context: &'static str,
        reason: String,
    },
}

/// Releases expired preparations, then decides whether `intent_id` is
/// claimable. A rejected claim records its own failure here, so the caller
/// commits that record before reporting the refusal.
pub(super) async fn screen_preparation_claim_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<PreparationClaim, CliError> {
    release_expired_preparations(transaction).await?;
    let Some(payload) = load_preparing_payload_in_tx(transaction, intent_id).await? else {
        return Ok(PreparationClaim::Unavailable(
            classify_unavailable_preparation_in_tx(transaction, intent_id).await?,
        ));
    };
    let preparation = decode_preparation(&payload)?;
    let (item, item_revision) = load_item_in_tx(transaction, &preparation.board_item_id)
        .await?
        .ok_or_else(|| {
            db_error(format!(
                "task-board item '{}' not found",
                preparation.board_item_id
            ))
        })?;
    if let Some(reason) = preparation_revision_error(&preparation, &item, item_revision) {
        return refuse_preparation_in_tx(
            transaction,
            intent_id,
            "stale task board preparation",
            reason.to_string(),
        )
        .await;
    }
    validate_reservable_item(&item, &preparation.plan)?;
    if let TaskBoardAdmissionCheck::Blocked(admission) =
        revalidate_dispatch_admission_in_tx(transaction, intent_id, &item, item_revision).await?
    {
        return refuse_preparation_in_tx(
            transaction,
            intent_id,
            "refused task board preparation",
            admission.refusal_message(),
        )
        .await;
    }
    Ok(PreparationClaim::Ready(Box::new(preparation)))
}

async fn load_preparing_payload_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<Option<String>, CliError> {
    query_as::<_, (String,)>(
        "SELECT payload_json FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND status = 'preparing'
           AND datetime(available_at) <= datetime('now')",
    )
    .bind(intent_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board preparation: {error}")))
    .map(|row| row.map(|row| row.0))
}

async fn refuse_preparation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    context: &'static str,
    reason: String,
) -> Result<PreparationClaim, CliError> {
    fail_preparation_admission_in_tx(transaction, intent_id, &reason).await?;
    Ok(PreparationClaim::Refused { context, reason })
}

/// Takes the lease on a screened preparation and reports the claim token. The
/// `UPDATE` re-checks `preparing`, so a preparation another worker claimed
/// first is left alone here; `ensure_preparation_claim` is what later refuses
/// a token that never took.
pub(super) async fn claim_preparation_intent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<String, CliError> {
    let claim_token = format!("dispatch-prepare-{}", Uuid::new_v4().simple());
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'preparing_claimed', attempts = attempts + 1,
             claim_token = ?2, claimed_at = ?3, updated_at = ?3
         WHERE intent_id = ?1 AND status = 'preparing'",
    )
    .bind(intent_id)
    .bind(&claim_token)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("claim task board preparation: {error}")))?;
    Ok(claim_token)
}

pub(super) async fn commit_preparation(
    transaction: Transaction<'_, Sqlite>,
    context: &str,
) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))
}

pub(super) fn decode_preparation(payload: &str) -> Result<TaskBoardDispatchPreparation, CliError> {
    serde_json::from_str(payload)
        .map_err(|error| db_error(format!("decode task board preparation: {error}")))
}
