use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use self::completion::{
    apply_dispatch_completion_in_tx, screen_dispatch_completion_in_tx, settle_dispatch_intent_in_tx,
};
use super::ITEMS_CHANGE_SCOPE;
use super::dispatch_workflow_start::validate_pending_dispatch;
use super::item_tx_ext::TaskBoardItemTxExt;
use super::items::bump_change_in_tx;
use super::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error, utc_now};
use crate::infra::io;
use crate::task_board::TaskBoardItem;
use crate::task_board::dispatch::DispatchLifecycle;
use crate::task_board::{DispatchAppliedTask, TaskBoardStatus, TaskBoardWorkflowStatus};

const CLAIM_LEASE_SECONDS: i64 = 30;

struct PendingTaskBoardDispatch {
    intent_id: String,
    payload_json: String,
    consumed_approval_grant_id: Option<String>,
    prior_status: String,
    compensation_pending: bool,
    last_error: Option<String>,
}

async fn load_pending_dispatch_claim(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
) -> Result<Option<PendingTaskBoardDispatch>, CliError> {
    query_as::<_, (String, String, Option<String>, String, bool, Option<String>)>(
        "SELECT intent_id, payload_json, consumed_approval_grant_id,
                    status, compensation_pending, last_error
             FROM task_board_dispatch_intents
             WHERE item_id = ?1
               AND (
                   (status = 'pending' AND datetime(available_at) <= datetime('now'))
                   OR (status = 'starting'
                       AND datetime(claimed_at) <= datetime('now', ?2))
               )
             ORDER BY created_at, intent_id LIMIT 1",
    )
    .bind(board_item_id)
    .bind(format!("-{CLAIM_LEASE_SECONDS} seconds"))
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| {
        row.map(
            |(
                intent_id,
                payload_json,
                consumed_approval_grant_id,
                prior_status,
                compensation_pending,
                last_error,
            )| PendingTaskBoardDispatch {
                intent_id,
                payload_json,
                consumed_approval_grant_id,
                prior_status,
                compensation_pending,
                last_error,
            },
        )
    })
    .map_err(|error| db_error(format!("load pending task board dispatch: {error}")))
}

/// Decide how a claimed dispatch should resume, refusing it in place when the
/// current item or policy state no longer allows the `Start` path.
///
/// Owns the transaction rather than borrowing it because the refusal branch
/// must commit and return early with the caller's own error, not roll the
/// refusal back.
async fn resolve_dispatch_claim_action_in_tx<'c>(
    mut transaction: Transaction<'c, Sqlite>,
    board_item_id: &str,
    pending: &PendingTaskBoardDispatch,
    applied: &DispatchAppliedTask,
) -> Result<(Transaction<'c, Sqlite>, TaskBoardDispatchClaimAction), CliError> {
    if pending.compensation_pending {
        let reason = pending
            .last_error
            .as_ref()
            .filter(|reason| !reason.is_empty())
            .cloned()
            .ok_or_else(|| db_error("compensating task board dispatch has no reason"))?;
        return Ok((
            transaction,
            TaskBoardDispatchClaimAction::Compensate { reason },
        ));
    }
    if pending.prior_status == "starting" {
        // A reclaimed `starting` claim can already own the deterministic
        // worker. Its recovery path must probe that identity before current
        // item or policy state is allowed to reject the intent.
        return Ok((transaction, TaskBoardDispatchClaimAction::Recover));
    }
    if let Err(error) = validate_pending_dispatch(
        &mut transaction,
        board_item_id,
        &pending.intent_id,
        applied,
        pending.consumed_approval_grant_id.as_deref(),
    )
    .await
    {
        transaction.commit().await.map_err(|commit_error| {
            db_error(format!(
                "commit refused task board worker claim: {commit_error}"
            ))
        })?;
        return Err(error);
    }
    Ok((transaction, TaskBoardDispatchClaimAction::Start))
}

#[path = "dispatch_intents_helpers.rs"]
pub(super) mod helpers;

#[derive(Debug)]
pub(crate) enum TaskBoardDispatchClaimAction {
    Start,
    Recover,
    Compensate { reason: String },
}

#[derive(Debug)]
pub(crate) struct ClaimedTaskBoardDispatch {
    pub(crate) intent_id: String,
    pub(crate) claim_token: String,
    pub(crate) applied: DispatchAppliedTask,
    pub(crate) consumed_approval_grant_id: Option<String>,
    pub(crate) action: TaskBoardDispatchClaimAction,
}

/// Real implementations behind the matching [`DispatchAdmissionQueries`]
/// methods, called from the single consolidated trait impl in
/// `dispatch_admission_queries.rs` (a trait's methods can only be implemented
/// in one `impl` block per type, so the per-area files hand it plain
/// functions instead of each declaring their own `impl DispatchAdmissionQueries
/// for AsyncDaemonDb`).
#[expect(
    clippy::cognitive_complexity,
    reason = "dispatch linking must keep item mutation and intent enqueue atomic"
)]
pub(super) async fn link_and_enqueue_task_board_dispatch(
    db: &AsyncDaemonDb,
    board_item_id: &str,
    session_id: &str,
    work_item_id: &str,
    lifecycle: &DispatchLifecycle,
) -> Result<DispatchAppliedTask, CliError> {
    io::validate_safe_segment(board_item_id)?;
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch enqueue")
        .await?;
    if let Some(existing) = active_intent_payload(&mut transaction, board_item_id).await? {
        let applied = ensure_dispatch_linkage(
            decode_applied(&existing)?,
            board_item_id,
            session_id,
            work_item_id,
        )?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit existing task board dispatch intent: {error}"
            ))
        })?;
        return Ok(applied);
    }
    let (mut item, revision) = transaction
        .load_item_in_tx(board_item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{board_item_id}' not found")))?;
    let before = item.clone();
    if item.workflow.execution_id.is_none() {
        item.workflow.execution_id = Some(new_workflow_execution_id());
    }
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("dispatch".to_string());
    item.workflow.attempts = item.workflow.attempts.saturating_add(1);
    item.workflow.push_policy_trace_id(new_policy_trace_id());
    item.status = TaskBoardStatus::InProgress;
    item.session_id = Some(session_id.to_string());
    item.work_item_id = Some(work_item_id.to_string());
    item.updated_at = utc_now();
    let write = replace_with_lane_transition_in_tx(
        &mut transaction,
        before,
        revision,
        item,
        LaneTransitionKind::Generic,
    )
    .await?;
    let change_sequence = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
    record_lane_transition_audit_in_tx(&mut transaction, &write, change_sequence).await?;
    let applied = DispatchAppliedTask {
        board_item_id: board_item_id.to_string(),
        session_id: Some(session_id.to_string()),
        workspace_id: None,
        working_copy_id: None,
        work_item_id: work_item_id.to_string(),
        lifecycle: lifecycle.clone(),
        item: write.item,
        read_only_workflow: None,
        write_workflow: None,
    };
    insert_intent(&mut transaction, &applied).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board dispatch enqueue: {error}")))?;
    Ok(applied)
}

pub(super) async fn claim_task_board_dispatch(
    db: &AsyncDaemonDb,
    board_item_id: &str,
) -> Result<Option<ClaimedTaskBoardDispatch>, CliError> {
    io::validate_safe_segment(board_item_id)?;
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch claim")
        .await?;
    let Some(pending) = load_pending_dispatch_claim(&mut transaction, board_item_id).await? else {
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit empty task board dispatch claim: {error}"))
        })?;
        return Ok(None);
    };
    let applied = decode_applied(&pending.payload_json)?;
    let (mut transaction, action) =
        resolve_dispatch_claim_action_in_tx(transaction, board_item_id, &pending, &applied).await?;
    let claim_token = format!("dispatch-claim-{}", Uuid::new_v4().simple());
    let changed =
        claim_task_board_dispatch_intent_in_tx(&mut transaction, &pending, &claim_token).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board dispatch claim: {error}")))?;
    if changed == 0 {
        return Ok(None);
    }
    Ok(Some(ClaimedTaskBoardDispatch {
        intent_id: pending.intent_id,
        claim_token,
        applied,
        consumed_approval_grant_id: pending.consumed_approval_grant_id,
        action,
    }))
}

pub(super) async fn claim_next_task_board_dispatch(
    db: &AsyncDaemonDb,
) -> Result<Option<ClaimedTaskBoardDispatch>, CliError> {
    let item_id = query_as::<_, (String,)>(
        "SELECT item_id FROM task_board_dispatch_intents
             WHERE status = 'pending'
                OR (status = 'starting'
                    AND datetime(claimed_at) <= datetime('now', ?1))
             ORDER BY created_at, intent_id LIMIT 1",
    )
    .bind(format!("-{CLAIM_LEASE_SECONDS} seconds"))
    .fetch_optional(db.pool())
    .await
    .map_err(|error| db_error(format!("load next task board dispatch: {error}")))?
    .map(|row| row.0);
    match item_id {
        Some(item_id) => claim_task_board_dispatch(db, &item_id).await,
        None => Ok(None),
    }
}

pub(super) async fn complete_task_board_dispatch(
    db: &AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
    managed_worker_id: &str,
) -> Result<TaskBoardItem, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch completion")
        .await?;
    let screened =
        screen_dispatch_completion_in_tx(&mut transaction, intent_id, claim_token).await?;
    let item = apply_dispatch_completion_in_tx(&mut transaction, *screened, intent_id).await?;
    settle_dispatch_intent_in_tx(&mut transaction, intent_id, claim_token, managed_worker_id)
        .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board dispatch completion: {error}")))?;
    Ok(item)
}

#[path = "dispatch_intents_completion.rs"]
mod completion;

/// Who a dispatch linked its ticket to.
///
/// Both halves travel together on purpose: a workspace item must not pass this
/// check on a Session match it never had, and comparing one field at a time is
/// how that slips through.
// Every field names an id because that is what the check compares; dropping the
// suffix would only make them read as the objects they point at.
#[expect(clippy::struct_field_names, reason = "each field really is an id")]
#[derive(Clone, Copy)]
pub(in crate::daemon::db::task_board) struct DispatchItemOwners<'a> {
    pub(in crate::daemon::db::task_board) session_id: Option<&'a str>,
    pub(in crate::daemon::db::task_board) workspace_id: Option<&'a str>,
    pub(in crate::daemon::db::task_board) work_item_id: &'a str,
}

impl<'a> DispatchItemOwners<'a> {
    pub(in crate::daemon::db::task_board) fn of(applied: &'a DispatchAppliedTask) -> Self {
        Self {
            session_id: applied.session_id.as_deref(),
            workspace_id: applied.workspace_id.as_deref(),
            work_item_id: applied.work_item_id.as_str(),
        }
    }
}

pub(super) fn ensure_dispatch_item_startable(
    item: &TaskBoardItem,
    owners: DispatchItemOwners<'_>,
    execution_id: Option<&str>,
) -> Result<(), CliError> {
    let matches = !item.is_deleted()
        && item.status == TaskBoardStatus::InProgress
        && item.workflow.status == TaskBoardWorkflowStatus::Running
        && item.session_id.as_deref() == owners.session_id
        && item.workspace_id.as_deref() == owners.workspace_id
        && item.work_item_id.as_deref() == Some(owners.work_item_id)
        && item.workflow.execution_id.as_deref() == execution_id;
    if matches {
        Ok(())
    } else {
        Err(CliErrorKind::invalid_transition(format!(
            "task-board item '{}' is no longer startable for its claimed dispatch",
            item.id
        ))
        .into())
    }
}

fn ensure_dispatch_linkage(
    applied: DispatchAppliedTask,
    board_item_id: &str,
    session_id: &str,
    work_item_id: &str,
) -> Result<DispatchAppliedTask, CliError> {
    let matches = applied.board_item_id == board_item_id
        && applied.session_id.as_deref() == Some(session_id)
        && applied.work_item_id == work_item_id;
    if matches {
        return Ok(applied);
    }
    Err(CliErrorKind::session_agent_conflict(format!(
        "task-board dispatch intent for item '{}' links session '{:?}' work item '{}', not requested item '{board_item_id}' session '{session_id}' work item '{work_item_id}'",
        applied.board_item_id, applied.session_id, applied.work_item_id
    ))
    .into())
}

async fn active_intent_payload(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<String>, CliError> {
    query_as::<_, (String,)>(
        "SELECT payload_json FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND status IN ('pending', 'starting', 'workflow_prepared')
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| row.map(|row| row.0))
    .map_err(|error| db_error(format!("load active task board dispatch intent: {error}")))
}

async fn claim_task_board_dispatch_intent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    pending: &PendingTaskBoardDispatch,
    claim_token: &str,
) -> Result<u64, CliError> {
    query(
        "UPDATE task_board_dispatch_intents SET status = 'starting', attempts = attempts + 1,
         claim_token = ?2, claimed_at = ?3, updated_at = ?3
         WHERE intent_id = ?1 AND compensation_pending = ?4
           AND (
               (?5 = 'pending' AND status = 'pending')
               OR (?5 = 'starting' AND status = 'starting'
                   AND datetime(claimed_at) <= datetime('now', ?6))
           )",
    )
    .bind(&pending.intent_id)
    .bind(claim_token)
    .bind(utc_now())
    .bind(pending.compensation_pending)
    .bind(&pending.prior_status)
    .bind(format!("-{CLAIM_LEASE_SECONDS} seconds"))
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("claim task board dispatch: {error}")))
}

async fn insert_intent(
    transaction: &mut Transaction<'_, Sqlite>,
    applied: &DispatchAppliedTask,
) -> Result<(), CliError> {
    let intent_id = format!("dispatch-intent-{}", Uuid::new_v4().simple());
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .ok_or_else(|| db_error("task board dispatch item has no workflow execution id"))?;
    let payload = serde_json::to_string(applied)
        .map_err(|error| db_error(format!("serialize task board dispatch intent: {error}")))?;
    let now = utc_now();
    query(
        "INSERT INTO task_board_dispatch_intents (
            intent_id, item_id, session_id, work_item_id, workflow_execution_id, payload_json,
            status, attempts, available_at, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', 0, ?7, ?7, ?7)",
    )
    .bind(intent_id)
    .bind(&applied.board_item_id)
    .bind(&applied.session_id)
    .bind(&applied.work_item_id)
    .bind(execution_id)
    .bind(payload)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task board dispatch intent: {error}")))?;
    Ok(())
}

pub(super) async fn claimed_intent_identity(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<(String, Option<String>, String, String), CliError> {
    query_as::<_, (String, Option<String>, String, String)>(
        "SELECT item_id, session_id, work_item_id, workflow_execution_id
         FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
           AND compensation_pending = 0",
    )
    .bind(intent_id)
    .bind(claim_token)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load claimed task board dispatch: {error}")))?
    .ok_or_else(|| {
        db_error(format!(
            "task board dispatch intent '{intent_id}' is not claimed"
        ))
    })
}

pub(super) fn decode_applied(payload: &str) -> Result<DispatchAppliedTask, CliError> {
    serde_json::from_str(payload)
        .map_err(|error| db_error(format!("decode task board dispatch intent: {error}")))
}

fn new_workflow_execution_id() -> String {
    format!("workflow-{}", Uuid::new_v4().simple())
}

fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", Uuid::new_v4().simple())
}
