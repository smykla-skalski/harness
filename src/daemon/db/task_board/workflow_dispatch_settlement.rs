use sqlx::{Sqlite, Transaction, query};

use super::ITEMS_CHANGE_SCOPE;
use super::admission_lifecycle::{
    renew_dispatch_admission_in_tx, validate_worker_start_fence_in_tx,
};
use super::dispatch_intents::{claimed_intent_identity, ensure_dispatch_item_startable};
use super::dispatch_workflow_start::{
    insert_started_workflow_in_tx, load_claimed_applied, workflow_start_fence,
};
use super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use super::remote_assignment_model::load_assignment_in_tx;
use super::workflow_dispatch::workflow_owner;
use super::workflow_executions::load_execution_in_tx;
use super::workflow_start_admission::commit_frozen_start_admission_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    DispatchAppliedTask, TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE, TASK_BOARD_EXECUTION_TARGET_RESOURCE,
    TaskBoardExecutionAttemptRecord, TaskBoardItem, TaskBoardWorkflowExecutionRecord,
};

impl AsyncDaemonDb {
    /// Persist a workflow execution and its first attempt without charging admission.
    pub(crate) async fn prepare_task_board_workflow_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<TaskBoardItem, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board workflow dispatch preparation")
            .await?;
        let (item_id, session_id, work_item_id, execution_id) =
            claimed_intent_identity(&mut transaction, intent_id, claim_token).await?;
        let applied = load_claimed_applied(&mut transaction, intent_id, claim_token).await?;
        ensure_workflow_launch(&applied)?;
        let (mut item, revision) = load_item_in_tx(&mut transaction, &item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        validate_claimed_identity(&item, &session_id, &work_item_id, &execution_id, &applied)?;
        let (prepared_revision, configuration_revision) = workflow_start_fence(&applied)?
            .ok_or_else(|| db_error("workflow dispatch has no immutable start fence"))?;
        validate_worker_start_fence_in_tx(
            &mut transaction,
            Some((prepared_revision, configuration_revision)),
            revision,
        )
        .await?;
        ensure_dispatch_item_startable(&item, &session_id, &work_item_id, Some(&execution_id))?;
        item.workflow.current_step_id = Some("workflow_prepared".into());
        item.updated_at = utc_now();
        let started_revision = revision
            .checked_add(1)
            .ok_or_else(|| db_error("workflow item revision is out of range"))?;
        replace_item_in_tx(&mut transaction, &item, started_revision).await?;
        insert_started_workflow_in_tx(
            &mut transaction,
            &item,
            started_revision,
            intent_id,
            &applied,
        )
        .await?;
        mark_workflow_prepared(&mut transaction, intent_id, claim_token).await?;
        renew_dispatch_admission_in_tx(&mut transaction, intent_id).await?;
        bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board workflow dispatch preparation: {error}"
            ))
        })?;
        Ok(item)
    }

    /// Commit admission only after the exact local or remote worker durably started.
    pub(crate) async fn complete_task_board_workflow_dispatch_start(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board workflow dispatch start completion")
            .await?;
        let execution = load_execution_in_tx(&mut transaction, execution_id)
            .await?
            .ok_or_else(|| db_error("workflow execution disappeared before start completion"))?;
        let Some(intent_id) = prepared_intent_id(&mut transaction, execution_id).await? else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit completed workflow dispatch no-op: {error}"))
            })?;
            return Ok(false);
        };
        if !workflow_start_is_durable_in_tx(&mut transaction, &execution).await? {
            return Err(db_error(
                "workflow target has not durably confirmed its exact start",
            ));
        }
        commit_frozen_start_admission_in_tx(
            &mut transaction,
            &intent_id,
            &workflow_owner(execution_id),
        )
        .await?;
        let now = utc_now();
        let changed = query(
            "UPDATE task_board_dispatch_intents
             SET status = 'completed', last_error = NULL, updated_at = ?2, completed_at = ?2
             WHERE intent_id = ?1 AND status = 'workflow_prepared'",
        )
        .bind(&intent_id)
        .bind(now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("complete prepared workflow dispatch: {error}")))?
        .rows_affected();
        if changed != 1 {
            return Err(db_error(
                "prepared workflow dispatch changed before start completion",
            ));
        }
        bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board workflow dispatch start: {error}"
            ))
        })?;
        Ok(true)
    }
}

async fn prepared_intent_id(
    transaction: &mut Transaction<'_, Sqlite>,
    execution_id: &str,
) -> Result<Option<String>, CliError> {
    sqlx::query_scalar(
        "SELECT intent_id FROM task_board_dispatch_intents
         WHERE workflow_execution_id = ?1 AND status = 'workflow_prepared'",
    )
    .bind(execution_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load prepared workflow dispatch: {error}")))
}

fn target_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<&TaskBoardExecutionAttemptRecord, CliError> {
    let action = target_resource(execution, TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)?;
    let attempt = target_resource(execution, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)?
        .parse::<u32>()
        .ok()
        .filter(|attempt| *attempt > 0)
        .ok_or_else(|| db_error("workflow execution target attempt is invalid"))?;
    execution
        .attempts
        .iter()
        .find(|candidate| candidate.action_key == action && candidate.attempt == attempt)
        .ok_or_else(|| db_error("workflow execution target attempt disappeared"))
}

pub(super) async fn workflow_start_is_durable_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    let Some(target) = execution
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(false);
    };
    let attempt = target_attempt(execution)?;
    if target == "local" {
        return local_start_is_durable(transaction, execution, attempt).await;
    }
    let assignment_id = target
        .strip_prefix("remote:")
        .filter(|assignment| !assignment.trim().is_empty())
        .ok_or_else(|| db_error("workflow execution target is invalid"))?;
    let assignment = load_assignment_in_tx(transaction, assignment_id)
        .await?
        .ok_or_else(|| db_error("remote assignment disappeared before admission commit"))?;
    let exact = assignment.execution_id == execution.execution_id
        && assignment.action_key.as_deref() == Some(attempt.action_key.as_str())
        && assignment.attempt == Some(attempt.attempt)
        && assignment.idempotency_key == attempt.idempotency_key
        && execution.ownership.host_id.as_deref() == Some(assignment.host_id.as_str())
        && execution.ownership.fencing_epoch == assignment.fencing_epoch;
    if !exact {
        return Err(db_error(
            "remote assignment does not match the exact workflow target",
        ));
    }
    let promoted = !matches!(
        attempt.state,
        crate::task_board::TaskBoardAttemptState::Preparing
            | crate::task_board::TaskBoardAttemptState::Starting
    ) && !matches!(
        execution.transition.execution_state,
        crate::task_board::TaskBoardExecutionState::Pending
            | crate::task_board::TaskBoardExecutionState::Preparing
            | crate::task_board::TaskBoardExecutionState::Starting
    );
    let started = assignment.started_at.is_some()
        && assignment
            .workspace_ref
            .as_deref()
            .is_some_and(|workspace| !workspace.trim().is_empty());
    if started {
        if !promoted {
            return Err(db_error(
                "remote assignment start evidence precedes workflow promotion",
            ));
        }
        return Ok(assignment.claimed_at.is_some()
            && matches!(
                assignment.state,
                crate::task_board::TaskBoardRemoteAssignmentState::Started
                    | crate::task_board::TaskBoardRemoteAssignmentState::Running
                    | crate::task_board::TaskBoardRemoteAssignmentState::Completed
                    | crate::task_board::TaskBoardRemoteAssignmentState::Failed
                    | crate::task_board::TaskBoardRemoteAssignmentState::Cancelled
                    | crate::task_board::TaskBoardRemoteAssignmentState::Unknown
                    | crate::task_board::TaskBoardRemoteAssignmentState::Superseded
            ));
    }
    if assignment.started_at.is_none() && assignment.workspace_ref.is_none() {
        Ok(false)
    } else {
        Err(db_error("remote assignment start evidence is incomplete"))
    }
}

async fn local_start_is_durable(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<bool, CliError> {
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM codex_runs
             WHERE run_id = ?1 AND workflow_execution_id = ?2 AND board_item_id = ?3
         )",
    )
    .bind(&attempt.idempotency_key)
    .bind(&execution.execution_id)
    .bind(&execution.item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load local workflow start evidence: {error}")))?;
    Ok(exists)
}

fn target_resource<'a>(
    execution: &'a TaskBoardWorkflowExecutionRecord,
    key: &str,
) -> Result<&'a str, CliError> {
    execution
        .ownership
        .resources
        .get(key)
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            db_error(format!(
                "workflow execution target resource '{key}' is missing"
            ))
        })
}

fn ensure_workflow_launch(applied: &DispatchAppliedTask) -> Result<(), CliError> {
    match (&applied.read_only_workflow, &applied.write_workflow) {
        (Some(_), None) | (None, Some(_)) => Ok(()),
        (Some(_), Some(_)) => Err(db_error("dispatch carries conflicting workflow launches")),
        (None, None) => Err(db_error("dispatch does not carry a workflow launch")),
    }
}

fn validate_claimed_identity(
    item: &TaskBoardItem,
    session_id: &str,
    work_item_id: &str,
    execution_id: &str,
    applied: &DispatchAppliedTask,
) -> Result<(), CliError> {
    let linked = item.session_id.as_deref() == Some(session_id)
        && item.work_item_id.as_deref() == Some(work_item_id)
        && item.workflow.execution_id.as_deref() == Some(execution_id)
        && applied.board_item_id == item.id
        && applied.session_id == session_id
        && applied.work_item_id == work_item_id
        && applied.item.workflow.execution_id.as_deref() == Some(execution_id);
    if linked {
        Ok(())
    } else {
        Err(db_error(format!(
            "task board workflow dispatch '{}' no longer matches its item linkage",
            item.id
        )))
    }
}

async fn mark_workflow_prepared(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<(), CliError> {
    let now = utc_now();
    let changed = query(
        "UPDATE task_board_dispatch_intents
         SET status = 'workflow_prepared', claim_token = NULL, claimed_at = NULL,
             last_error = NULL, updated_at = ?3
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'
           AND compensation_pending = 0",
    )
    .bind(intent_id)
    .bind(claim_token)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("mark workflow dispatch prepared: {error}")))?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(db_error(format!(
            "task board dispatch intent '{intent_id}' lost its claim"
        )))
    }
}
