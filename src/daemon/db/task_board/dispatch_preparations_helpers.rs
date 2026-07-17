use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::{
    ClaimedTaskBoardDispatchPreparation, PREPARATION_LEASE_SECONDS, ReservedTaskBoardDispatch,
    TaskBoardDispatchPreparation,
};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::session::types::TaskSeverity;
use crate::task_board::{
    DispatchPlan, SessionIntent, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TaskBoardWorkflowStatus,
};

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
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'failed', last_error = ?2, completed_at = ?3, updated_at = ?3
         WHERE intent_id = ?1 AND status IN ('preparing', 'preparing_claimed')",
    )
    .bind(intent_id)
    .bind(reason)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("refuse task board preparation admission: {error}")))?;
    Ok(())
}

pub(super) async fn active_reservation(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<ReservedTaskBoardDispatch>, CliError> {
    let row = query_as::<_, (String, String, String)>(
        "SELECT intent_id, status, payload_json FROM task_board_dispatch_intents
         WHERE item_id = ?1
           AND status IN ('preparing', 'preparing_claimed', 'held', 'pending', 'starting')
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
                preparation: decode_preparation(&payload)?,
            })
        } else {
            serde_json::from_str(&payload)
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

pub(super) fn decode_preparation(payload: &str) -> Result<TaskBoardDispatchPreparation, CliError> {
    serde_json::from_str(payload)
        .map_err(|error| db_error(format!("decode task board preparation: {error}")))
}
