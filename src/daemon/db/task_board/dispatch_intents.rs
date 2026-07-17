use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::ITEMS_CHANGE_SCOPE;
use super::admission_lifecycle::{
    TaskBoardAdmissionCheck, commit_dispatch_admission_in_tx, revalidate_dispatch_admission_in_tx,
};
use super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use super::workflow_dispatch::insert_started_read_only_workflow_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error, utc_now};
use crate::infra::io;
use crate::task_board::dispatch::DispatchLifecycle;
use crate::task_board::{DispatchAppliedTask, TaskBoardStatus, TaskBoardWorkflowStatus};

const CLAIM_LEASE_SECONDS: i64 = 30;

#[path = "dispatch_intents_helpers.rs"]
mod helpers;
use helpers::refuse_pending_admission_in_tx;

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

impl AsyncDaemonDb {
    /// Atomically link a Task Board item to its created task and enqueue worker startup.
    #[expect(
        clippy::cognitive_complexity,
        reason = "dispatch linking must keep item mutation and intent enqueue atomic"
    )]
    pub(crate) async fn link_and_enqueue_task_board_dispatch(
        &self,
        board_item_id: &str,
        session_id: &str,
        work_item_id: &str,
        lifecycle: &DispatchLifecycle,
    ) -> Result<DispatchAppliedTask, CliError> {
        io::validate_safe_segment(board_item_id)?;
        let mut transaction = self
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
        let (mut item, revision) = load_item_in_tx(&mut transaction, board_item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{board_item_id}' not found")))?;
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
        replace_item_in_tx(&mut transaction, &item, revision + 1).await?;
        let applied = DispatchAppliedTask {
            board_item_id: board_item_id.to_string(),
            session_id: session_id.to_string(),
            work_item_id: work_item_id.to_string(),
            lifecycle: lifecycle.clone(),
            item,
            read_only_workflow: None,
        };
        insert_intent(&mut transaction, &applied).await?;
        bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board dispatch enqueue: {error}")))?;
        Ok(applied)
    }

    /// Claim one pending or lease-expired worker startup for an item.
    pub(crate) async fn claim_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatch>, CliError> {
        io::validate_safe_segment(board_item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board dispatch claim")
            .await?;
        let Some((
            intent_id,
            payload_json,
            consumed_approval_grant_id,
            prior_status,
            compensation_pending,
            last_error,
        )) = query_as::<_, (String, String, Option<String>, String, bool, Option<String>)>(
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
        .map_err(|error| db_error(format!("load pending task board dispatch: {error}")))?
        else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit empty task board dispatch claim: {error}"))
            })?;
            return Ok(None);
        };
        let applied = decode_applied(&payload_json)?;
        let action = if compensation_pending {
            TaskBoardDispatchClaimAction::Compensate {
                reason: last_error
                    .filter(|reason| !reason.is_empty())
                    .ok_or_else(|| db_error("compensating task board dispatch has no reason"))?,
            }
        } else if prior_status == "starting" {
            // A reclaimed `starting` claim can already own the deterministic
            // worker. Its recovery path must probe that identity before current
            // item or policy state is allowed to reject the intent.
            TaskBoardDispatchClaimAction::Recover
        } else {
            if let Err(error) = validate_pending_dispatch(
                &mut transaction,
                board_item_id,
                &intent_id,
                &applied,
                consumed_approval_grant_id.as_deref(),
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
            TaskBoardDispatchClaimAction::Start
        };
        let claim_token = format!("dispatch-claim-{}", Uuid::new_v4().simple());
        let changed = query(
            "UPDATE task_board_dispatch_intents SET status = 'starting', attempts = attempts + 1,
             claim_token = ?2, claimed_at = ?3, updated_at = ?3
             WHERE intent_id = ?1 AND compensation_pending = ?4
               AND (
                   (?5 = 'pending' AND status = 'pending')
                   OR (?5 = 'starting' AND status = 'starting'
                       AND datetime(claimed_at) <= datetime('now', ?6))
               )",
        )
        .bind(&intent_id)
        .bind(&claim_token)
        .bind(utc_now())
        .bind(compensation_pending)
        .bind(&prior_status)
        .bind(format!("-{CLAIM_LEASE_SECONDS} seconds"))
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("claim task board dispatch: {error}")))?
        .rows_affected();
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board dispatch claim: {error}")))?;
        if changed == 0 {
            return Ok(None);
        }
        Ok(Some(ClaimedTaskBoardDispatch {
            intent_id,
            claim_token,
            applied,
            consumed_approval_grant_id,
            action,
        }))
    }

    /// Claim the next pending worker startup, including lease-expired work after restart.
    pub(crate) async fn claim_next_task_board_dispatch(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatch>, CliError> {
        let item_id = query_as::<_, (String,)>(
            "SELECT item_id FROM task_board_dispatch_intents
             WHERE status = 'pending'
                OR (status = 'starting'
                    AND datetime(claimed_at) <= datetime('now', ?1))
             ORDER BY created_at, intent_id LIMIT 1",
        )
        .bind(format!("-{CLAIM_LEASE_SECONDS} seconds"))
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load next task board dispatch: {error}")))?
        .map(|row| row.0);
        match item_id {
            Some(item_id) => self.claim_task_board_dispatch(&item_id).await,
            None => Ok(None),
        }
    }

    pub(crate) async fn complete_task_board_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
    ) -> Result<crate::task_board::TaskBoardItem, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board dispatch completion")
            .await?;
        let (item_id, session_id, work_item_id, execution_id) =
            claimed_intent_identity(&mut transaction, intent_id, claim_token).await?;
        let (mut item, revision) = load_item_in_tx(&mut transaction, &item_id)
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
        ensure_dispatch_item_startable(&item, &session_id, &work_item_id, Some(&execution_id))?;
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("worker_running".to_string());
        item.workflow.last_error = None;
        item.updated_at = utc_now();
        replace_item_in_tx(&mut transaction, &item, revision + 1).await?;
        if let Some(launch) =
            claimed_intent_read_only_launch(&mut transaction, intent_id, claim_token).await?
        {
            insert_started_read_only_workflow_in_tx(
                &mut transaction,
                &item,
                revision + 1,
                intent_id,
                &launch,
            )
            .await?;
        }
        bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        let now = utc_now();
        let changed = query(
            "UPDATE task_board_dispatch_intents SET status = 'completed', last_error = NULL,
             claim_token = NULL, claimed_at = NULL, updated_at = ?3, completed_at = ?3
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
               AND compensation_pending = 0",
        )
        .bind(intent_id)
        .bind(claim_token)
        .bind(now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("complete task board dispatch intent: {error}")))?
        .rows_affected();
        if changed != 1 {
            return Err(db_error(format!(
                "task board dispatch intent '{intent_id}' is not claimed"
            )));
        }
        commit_dispatch_admission_in_tx(&mut transaction, intent_id, managed_worker_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board dispatch completion: {error}")))?;
        Ok(item)
    }
}

async fn claimed_intent_read_only_launch(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<Option<crate::task_board::TaskBoardReadOnlyWorkflowLaunch>, CliError> {
    let payload = query_as::<_, (String,)>(
        "SELECT payload_json FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'",
    )
    .bind(intent_id)
    .bind(claim_token)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load claimed read-only workflow launch: {error}")))?
    .0;
    decode_applied(&payload).map(|applied| applied.read_only_workflow)
}

async fn validate_pending_dispatch(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
    intent_id: &str,
    applied: &DispatchAppliedTask,
    consumed_approval_grant_id: Option<&str>,
) -> Result<(), CliError> {
    let (item, item_revision) = load_item_in_tx(transaction, board_item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{board_item_id}' not found")))?;
    if let Err(error) = ensure_dispatch_item_startable(
        &item,
        &applied.session_id,
        &applied.work_item_id,
        applied.item.workflow.execution_id.as_deref(),
    ) {
        refuse_pending_admission_in_tx(
            transaction,
            intent_id,
            applied,
            consumed_approval_grant_id,
            &error.to_string(),
        )
        .await?;
        return Err(error);
    }
    if let TaskBoardAdmissionCheck::Blocked(admission) =
        revalidate_dispatch_admission_in_tx(transaction, intent_id, &item, item_revision).await?
    {
        refuse_pending_admission_in_tx(
            transaction,
            intent_id,
            applied,
            consumed_approval_grant_id,
            &admission.refusal_message(),
        )
        .await?;
        return Err(CliErrorKind::invalid_transition(admission.refusal_message()).into());
    }
    Ok(())
}

pub(super) fn ensure_dispatch_item_startable(
    item: &crate::task_board::TaskBoardItem,
    session_id: &str,
    work_item_id: &str,
    execution_id: Option<&str>,
) -> Result<(), CliError> {
    let matches = !item.is_deleted()
        && item.status == TaskBoardStatus::InProgress
        && item.workflow.status == TaskBoardWorkflowStatus::Running
        && item.session_id.as_deref() == Some(session_id)
        && item.work_item_id.as_deref() == Some(work_item_id)
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
        && applied.session_id == session_id
        && applied.work_item_id == work_item_id;
    if matches {
        return Ok(applied);
    }
    Err(CliErrorKind::session_agent_conflict(format!(
        "task-board dispatch intent for item '{}' links session '{}' work item '{}', not requested item '{board_item_id}' session '{session_id}' work item '{work_item_id}'",
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
         WHERE item_id = ?1 AND status IN ('pending', 'starting')
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| row.map(|row| row.0))
    .map_err(|error| db_error(format!("load active task board dispatch intent: {error}")))
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

async fn claimed_intent_identity(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<(String, String, String, String), CliError> {
    query_as::<_, (String, String, String, String)>(
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
