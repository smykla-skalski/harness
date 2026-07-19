use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::super::ITEMS_CHANGE_SCOPE;
use super::super::admission_lifecycle::{
    commit_compensating_dispatch_admission_in_tx, finalize_compensating_dispatch_admission_in_tx,
    release_dispatch_admission_in_tx, renew_frozen_dispatch_admission_in_tx,
};
use super::super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use crate::daemon::db::policy::restore_consumed_approval_grant_in_tx_at;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    DispatchAppliedTask, TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus,
};

pub(in crate::daemon::db::task_board) async fn refuse_pending_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    applied: &DispatchAppliedTask,
    consumed_approval_grant_id: Option<&str>,
    reason: &str,
) -> Result<(), CliError> {
    if let Some(grant_id) = consumed_approval_grant_id {
        restore_consumed_approval_grant_in_tx_at(transaction.as_mut(), grant_id, &utc_now())
            .await?;
    }
    let (mut item, revision) = load_item_in_tx(transaction, &applied.board_item_id)
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
        item.workflow.status = TaskBoardWorkflowStatus::Failed;
        item.workflow.current_step_id = Some("admission".to_string());
        item.workflow.last_error = Some(reason.to_string());
        item.status = TaskBoardStatus::Todo;
        item.session_id = None;
        item.work_item_id = None;
        item.updated_at = utc_now();
        replace_item_in_tx(transaction, &item, revision + 1).await?;
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    }
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
    release_dispatch_admission_in_tx(transaction, intent_id).await?;
    Ok(())
}

pub(super) fn dispatch_item_can_be_rolled_back(item: &TaskBoardItem) -> bool {
    !item.is_deleted()
        && item.status == TaskBoardStatus::InProgress
        && item.workflow.status == TaskBoardWorkflowStatus::Running
}

impl AsyncDaemonDb {
    pub(crate) async fn begin_task_board_dispatch_compensation(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
        reason: &str,
    ) -> Result<(), CliError> {
        if reason.is_empty() {
            return Err(db_error("task board dispatch compensation reason is empty"));
        }
        let mut transaction = self
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
        commit_compensating_dispatch_admission_in_tx(
            &mut transaction,
            intent_id,
            managed_worker_id,
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board dispatch compensation marker: {error}"
            ))
        })
    }

    pub(crate) async fn task_board_dispatch_is_completed(
        &self,
        applied: &DispatchAppliedTask,
    ) -> Result<bool, CliError> {
        self.task_board_dispatch_has_status(applied, "completed")
            .await
    }

    pub(crate) async fn task_board_dispatch_completion_matches(
        &self,
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
        .fetch_one(self.pool())
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
        .fetch_one(self.pool())
        .await
        .map_err(|error| {
            db_error(format!(
                "check exact task board workflow completion evidence: {error}"
            ))
        })
    }

    pub(crate) async fn task_board_dispatch_is_held(
        &self,
        applied: &DispatchAppliedTask,
    ) -> Result<bool, CliError> {
        self.task_board_dispatch_has_status(applied, "held").await
    }

    async fn task_board_dispatch_has_status(
        &self,
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
        .fetch_one(self.pool())
        .await
        .map_err(|error| db_error(format!("check task board dispatch status: {error}")))
    }

    pub(crate) async fn renew_task_board_dispatch_claim(
        &self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<(), CliError> {
        let mut transaction = self
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
            renew_frozen_dispatch_admission_in_tx(&mut transaction, intent_id).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board dispatch renewal: {error}")))
    }

    pub(crate) async fn fail_task_board_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
        consumed_approval_grant_id: Option<&str>,
        reason: &str,
    ) -> Result<(), CliError> {
        self.finish_failed_task_board_dispatch(
            intent_id,
            claim_token,
            consumed_approval_grant_id,
            None,
            reason,
            false,
        )
        .await
    }

    pub(crate) async fn finalize_task_board_dispatch_compensation(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
        reason: &str,
    ) -> Result<(), CliError> {
        self.finish_failed_task_board_dispatch(
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
        &self,
        intent_id: &str,
        claim_token: &str,
        consumed_approval_grant_id: Option<&str>,
        managed_worker_id: Option<&str>,
        reason: &str,
        expected_compensation: bool,
    ) -> Result<(), CliError> {
        let mut transaction = self
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
        let (mut item, revision) = load_item_in_tx(&mut transaction, &item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        let still_linked = item.session_id.as_deref() == Some(session_id.as_str())
            && item.work_item_id.as_deref() == Some(work_item_id.as_str())
            && item.workflow.execution_id.as_deref() == Some(execution_id.as_str());
        if still_linked && dispatch_item_can_be_rolled_back(&item) {
            item.workflow.status = TaskBoardWorkflowStatus::Failed;
            item.workflow.current_step_id = Some("worker_spawn".to_string());
            item.workflow.last_error = Some(reason.to_string());
            item.status = TaskBoardStatus::Todo;
            item.session_id = None;
            item.work_item_id = None;
            item.updated_at = utc_now();
            replace_item_in_tx(&mut transaction, &item, revision + 1).await?;
            bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
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
        if let Some(managed_worker_id) = managed_worker_id {
            finalize_compensating_dispatch_admission_in_tx(
                &mut transaction,
                intent_id,
                managed_worker_id,
            )
            .await?;
        } else {
            release_dispatch_admission_in_tx(&mut transaction, intent_id).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board dispatch failure: {error}")))
    }
}

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
