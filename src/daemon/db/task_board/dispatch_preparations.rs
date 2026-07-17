use serde::{Deserialize, Serialize};
use sqlx::{query, query_as};
use uuid::Uuid;

use super::ITEMS_CHANGE_SCOPE;
use super::admission::{TaskBoardDispatchAdmissionSnapshot, evaluate_dispatch_admission_in_tx};
use super::admission_lifecycle::{
    TaskBoardAdmissionCheck, renew_dispatch_admission_in_tx, revalidate_dispatch_admission_in_tx,
};
use super::admission_reservations::persist_admission_snapshot_in_tx;
use super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use crate::daemon::db::policy::consume_approval_grant_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::task_board::{
    DispatchAppliedTask, DispatchPlan, SessionIntent, TaskBoardReadOnlyWorkflowLaunch,
};

const PREPARATION_LEASE_SECONDS: i64 = 30;

#[path = "dispatch_preparations_helpers.rs"]
mod helpers;
use helpers::{
    active_reservation, apply_preparation_to_item, decode_preparation, ensure_preparation_claim,
    fail_preparation_admission_in_tx, insert_preparation, release_expired_preparations,
    validate_reservable_item,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TaskBoardDispatchPreparation {
    pub(crate) board_item_id: String,
    pub(crate) session_id: String,
    pub(crate) work_item_id: String,
    pub(crate) workflow_execution_id: String,
    pub(crate) actor: String,
    pub(crate) project_dir: Option<String>,
    pub(crate) plan: DispatchPlan,
    #[serde(default)]
    pub(crate) hold_worker: bool,
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
    Blocked(TaskBoardDispatchAdmissionSnapshot),
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
        hold_worker: bool,
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
        let (item, item_revision) = load_item_in_tx(&mut transaction, &plan.board_item_id)
            .await?
            .ok_or_else(|| {
                db_error(format!(
                    "task-board item '{}' not found",
                    plan.board_item_id
                ))
            })?;
        validate_reservable_item(&item, plan)?;
        let mut admission =
            evaluate_dispatch_admission_in_tx(&mut transaction, &item, item_revision, None).await?;
        if admission.as_ref().is_some_and(|value| !value.is_allowed()) {
            let mut admission = admission.take().expect("checked task board admission");
            persist_admission_snapshot_in_tx(
                &mut transaction,
                &plan.board_item_id,
                None,
                &mut admission,
            )
            .await?;
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit refused task board admission: {error}"))
            })?;
            return Ok(ReservedTaskBoardDispatch::Blocked(admission));
        }
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
            hold_worker,
        };
        insert_preparation(&mut transaction, &intent_id, &preparation).await?;
        if let Some(mut admission) = admission {
            persist_admission_snapshot_in_tx(
                &mut transaction,
                &plan.board_item_id,
                Some(&intent_id),
                &mut admission,
            )
            .await?;
        }
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
        let preparation = decode_preparation(&payload)?;
        let (item, item_revision) = load_item_in_tx(&mut transaction, &preparation.board_item_id)
            .await?
            .ok_or_else(|| {
                db_error(format!(
                    "task-board item '{}' not found",
                    preparation.board_item_id
                ))
            })?;
        validate_reservable_item(&item, &preparation.plan)?;
        if let TaskBoardAdmissionCheck::Blocked(admission) =
            revalidate_dispatch_admission_in_tx(&mut transaction, intent_id, &item, item_revision)
                .await?
        {
            fail_preparation_admission_in_tx(
                &mut transaction,
                intent_id,
                &admission.refusal_message(),
            )
            .await?;
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit refused task board preparation: {error}"))
            })?;
            return Err(crate::errors::CliErrorKind::invalid_transition(
                admission.refusal_message(),
            )
            .into());
        }
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
            preparation,
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
        let mut transaction = self
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
        renew_dispatch_admission_in_tx(&mut transaction, &claim.intent_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board preparation renewal: {error}")))
    }

    pub(crate) async fn complete_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
    ) -> Result<DispatchAppliedTask, CliError> {
        self.complete_task_board_dispatch_preparation_with_workflow(claim, branch, worktree, None)
            .await
    }

    /// Atomically link a prepared session task and expose it for worker startup.
    #[expect(
        clippy::cognitive_complexity,
        reason = "dispatch completion must keep item linking and intent publication atomic"
    )]
    pub(crate) async fn complete_task_board_dispatch_preparation_with_workflow(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
        read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
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
        apply_preparation_to_item(&mut item, preparation, branch, worktree);
        replace_item_in_tx(&mut transaction, &item, revision + 1).await?;
        // Immediate dispatch consumes its one-shot grant with publication.
        // Step-mode dispatch deliberately keeps the grant live while held;
        // delivery re-evaluates current policy and consumes atomically there.
        if !preparation.hold_worker
            && let Some(grant_id) = preparation.plan.consumed_approval_grant_id.as_deref()
        {
            let consumed = consume_approval_grant_in_tx(transaction.as_mut(), grant_id).await?;
            if !consumed {
                return Err(db_error(format!(
                    "approval grant already consumed; rebuild plan (grant '{grant_id}')"
                )));
            }
        }
        let applied = DispatchAppliedTask {
            board_item_id: preparation.board_item_id.clone(),
            session_id: preparation.session_id.clone(),
            work_item_id: preparation.work_item_id.clone(),
            lifecycle: preparation.plan.applied_lifecycle(),
            item,
            read_only_workflow,
        };
        let payload = serde_json::to_string(&applied).map_err(|error| {
            db_error(format!("serialize prepared task board dispatch: {error}"))
        })?;
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
