use serde::{Deserialize, Serialize};
use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::ITEMS_CHANGE_SCOPE;
use super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::session::types::TaskSeverity;
use crate::task_board::{
    DispatchAppliedTask, DispatchPlan, SessionIntent, TaskBoardItem, TaskBoardPriority,
    TaskBoardStatus, TaskBoardWorkflowStatus,
};

const PREPARATION_LEASE_SECONDS: i64 = 30;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TaskBoardDispatchPreparation {
    pub(crate) board_item_id: String,
    pub(crate) session_id: String,
    pub(crate) work_item_id: String,
    pub(crate) workflow_execution_id: String,
    pub(crate) actor: String,
    pub(crate) project_dir: Option<String>,
    pub(crate) plan: DispatchPlan,
}

#[derive(Debug, Clone)]
pub(crate) struct ClaimedTaskBoardDispatchPreparation {
    pub(crate) intent_id: String,
    pub(crate) claim_token: String,
    pub(crate) preparation: TaskBoardDispatchPreparation,
}

#[derive(Debug)]
pub(crate) enum ReservedTaskBoardDispatch {
    Preparing {
        intent_id: String,
        preparation: TaskBoardDispatchPreparation,
    },
    Applied(DispatchAppliedTask),
}

impl AsyncDaemonDb {
    /// Reserve one dispatch before creating its session or task side effects.
    #[expect(
        clippy::cognitive_complexity,
        reason = "dispatch reservation must validate and insert under one transaction"
    )]
    pub(crate) async fn reserve_task_board_dispatch(
        &self,
        plan: &DispatchPlan,
        actor: &str,
        project_dir: Option<&str>,
    ) -> Result<ReservedTaskBoardDispatch, CliError> {
        io::validate_safe_segment(&plan.board_item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board dispatch reservation")
            .await?;
        if let Some(reserved) = active_reservation(&mut transaction, &plan.board_item_id).await? {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit existing task board reservation: {error}"))
            })?;
            return Ok(reserved);
        }
        let (item, _) = load_item_in_tx(&mut transaction, &plan.board_item_id)
            .await?
            .ok_or_else(|| {
                db_error(format!(
                    "task-board item '{}' not found",
                    plan.board_item_id
                ))
            })?;
        validate_reservable_item(&item, plan)?;
        let intent_id = format!("dispatch-intent-{}", Uuid::new_v4().simple());
        let workflow_execution_id = format!("workflow-{}", Uuid::new_v4().simple());
        let session_id = match &plan.session {
            SessionIntent::Existing { session_id } => session_id.clone(),
            SessionIntent::Create { .. } => Uuid::new_v4().to_string(),
        };
        let preparation = TaskBoardDispatchPreparation {
            board_item_id: plan.board_item_id.clone(),
            session_id,
            work_item_id: format!("task-board-{}", Uuid::new_v4().simple()),
            workflow_execution_id,
            actor: actor.to_string(),
            project_dir: project_dir.map(ToString::to_string),
            plan: plan.clone(),
        };
        insert_preparation(&mut transaction, &intent_id, &preparation).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board dispatch reservation: {error}"))
        })?;
        Ok(ReservedTaskBoardDispatch::Preparing {
            intent_id,
            preparation,
        })
    }

    pub(crate) async fn claim_task_board_dispatch_preparation(
        &self,
        intent_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board dispatch preparation claim")
            .await?;
        release_expired_preparations(&mut transaction).await?;
        let Some(payload) = query_as::<_, (String,)>(
            "SELECT payload_json FROM task_board_dispatch_intents
             WHERE intent_id = ?1 AND status = 'preparing'
               AND datetime(available_at) <= datetime('now')",
        )
        .bind(intent_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board preparation: {error}")))?
        .map(|row| row.0) else {
            transaction.commit().await.map_err(|error| {
                db_error(format!(
                    "commit empty task board preparation claim: {error}"
                ))
            })?;
            return Ok(None);
        };
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
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board preparation claim: {error}")))?;
        Ok(Some(ClaimedTaskBoardDispatchPreparation {
            intent_id: intent_id.to_string(),
            claim_token,
            preparation: decode_preparation(&payload)?,
        }))
    }

    pub(crate) async fn claim_next_task_board_dispatch_preparation(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
        let intent_id = query_as::<_, (String,)>(
            "SELECT intent_id FROM task_board_dispatch_intents
             WHERE (status = 'preparing' AND datetime(available_at) <= datetime('now'))
                OR (status = 'preparing_claimed'
                    AND datetime(claimed_at) <= datetime('now', ?1))
             ORDER BY created_at, intent_id LIMIT 1",
        )
        .bind(format!("-{PREPARATION_LEASE_SECONDS} seconds"))
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load next task board preparation: {error}")))?
        .map(|row| row.0);
        match intent_id {
            Some(intent_id) => self.claim_task_board_dispatch_preparation(&intent_id).await,
            None => Ok(None),
        }
    }

    /// Renew a claimed preparation while its session or worktree is being created.
    pub(crate) async fn renew_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
    ) -> Result<(), CliError> {
        let changed = query(
            "UPDATE task_board_dispatch_intents
             SET claimed_at = ?3, updated_at = ?3
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
        )
        .bind(&claim.intent_id)
        .bind(&claim.claim_token)
        .bind(utc_now())
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("renew task board preparation: {error}")))?
        .rows_affected();
        if changed == 1 {
            Ok(())
        } else {
            Err(db_error(format!(
                "task board preparation '{}' lost its claim",
                claim.intent_id
            )))
        }
    }

    /// Atomically link a prepared session task and expose it for worker startup.
    #[expect(
        clippy::cognitive_complexity,
        reason = "dispatch completion must keep item linking and intent publication atomic"
    )]
    pub(crate) async fn complete_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
    ) -> Result<DispatchAppliedTask, CliError> {
        let mut transaction = self
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
        validate_reservable_item(&item, &preparation.plan)?;
        item.workflow.execution_id = Some(preparation.workflow_execution_id.clone());
        item.workflow.branch = Some(branch.to_string());
        item.workflow.worktree = Some(worktree.to_string());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("dispatch".to_string());
        item.workflow.attempts = item.workflow.attempts.saturating_add(1);
        item.workflow
            .push_policy_trace_id(format!("policy-trace-{}", Uuid::new_v4().simple()));
        item.status = TaskBoardStatus::InProgress;
        item.session_id = Some(preparation.session_id.clone());
        item.work_item_id = Some(preparation.work_item_id.clone());
        item.updated_at = utc_now();
        replace_item_in_tx(&mut transaction, &item, revision + 1).await?;
        let applied = DispatchAppliedTask {
            board_item_id: preparation.board_item_id.clone(),
            session_id: preparation.session_id.clone(),
            work_item_id: preparation.work_item_id.clone(),
            lifecycle: preparation.plan.applied_lifecycle(),
            item,
        };
        let payload = serde_json::to_string(&applied).map_err(|error| {
            db_error(format!("serialize prepared task board dispatch: {error}"))
        })?;
        query(
            "UPDATE task_board_dispatch_intents
             SET payload_json = ?3, status = 'pending', claim_token = NULL,
                 claimed_at = NULL, last_error = NULL, updated_at = ?4
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
        )
        .bind(&claim.intent_id)
        .bind(&claim.claim_token)
        .bind(payload)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("complete task board preparation: {error}")))?;
        bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board preparation completion: {error}"))
        })?;
        Ok(applied)
    }

    pub(crate) async fn release_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        reason: &str,
    ) -> Result<(), CliError> {
        let changed = query(
            "UPDATE task_board_dispatch_intents
             SET status = 'preparing', claim_token = NULL, claimed_at = NULL,
                 last_error = ?3, available_at = datetime('now', '+1 second'), updated_at = ?4
             WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'preparing_claimed'",
        )
        .bind(&claim.intent_id)
        .bind(&claim.claim_token)
        .bind(reason)
        .bind(utc_now())
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("release task board preparation: {error}")))?
        .rows_affected();
        if changed == 1 {
            Ok(())
        } else {
            Err(db_error(format!(
                "task board preparation '{}' is not claimed",
                claim.intent_id
            )))
        }
    }
}

async fn active_reservation(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<ReservedTaskBoardDispatch>, CliError> {
    let row = query_as::<_, (String, String, String)>(
        "SELECT intent_id, status, payload_json FROM task_board_dispatch_intents
         WHERE item_id = ?1
           AND status IN ('preparing', 'preparing_claimed', 'pending', 'starting')
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

async fn insert_preparation(
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

async fn release_expired_preparations(
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

async fn ensure_preparation_claim(
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

fn validate_reservable_item(item: &TaskBoardItem, plan: &DispatchPlan) -> Result<(), CliError> {
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

fn decode_preparation(payload: &str) -> Result<TaskBoardDispatchPreparation, CliError> {
    serde_json::from_str(payload)
        .map_err(|error| db_error(format!("decode task board preparation: {error}")))
}
