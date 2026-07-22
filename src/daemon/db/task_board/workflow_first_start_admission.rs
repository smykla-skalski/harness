use sqlx::{Sqlite, Transaction, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::admission_lifecycle::{TaskBoardAdmissionCheck, revalidate_dispatch_admission_in_tx};
use super::items::{bump_change_in_tx, load_item_in_tx};
use super::workflow_execution_attempts::{update_attempt_in_tx, validate_attempt_phase};
use super::workflow_executions::update_execution_in_tx;
use super::workflow_start_admission::{
    freeze_unconfigured_start_admission_in_tx, frozen_unconfigured_start_admission_in_tx,
};
use super::workflow_terminal::settle_prepared_dispatch_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionState, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    validate_task_board_attempt_update, validate_task_board_execution_update,
    validate_task_board_workflow_execution,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TaskBoardFirstStartAdmission {
    Ready,
    Settled,
}

pub(super) async fn revalidate_first_start_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<TaskBoardFirstStartAdmission, CliError> {
    let intent_id = query_scalar::<_, String>(
        "SELECT intent_id FROM task_board_dispatch_intents
         WHERE workflow_execution_id = ?1 AND item_id = ?2
           AND status = 'workflow_prepared'",
    )
    .bind(&parent.execution_id)
    .bind(&parent.item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workflow first-start admission: {error}")))?;
    let Some(intent_id) = intent_id else {
        return Ok(TaskBoardFirstStartAdmission::Ready);
    };
    if frozen_unconfigured_start_admission_in_tx(transaction, &intent_id).await? {
        return Ok(TaskBoardFirstStartAdmission::Ready);
    }
    let (item, item_revision) = load_item_in_tx(transaction, &parent.item_id)
        .await?
        .ok_or_else(|| db_error("workflow first-start item disappeared"))?;
    match revalidate_dispatch_admission_in_tx(transaction, &intent_id, &item, item_revision).await?
    {
        TaskBoardAdmissionCheck::Blocked(snapshot) => {
            settle_blocked_first_start_in_tx(
                transaction,
                parent,
                current_attempt,
                &snapshot.refusal_message(),
                now,
            )
            .await?;
            Ok(TaskBoardFirstStartAdmission::Settled)
        }
        TaskBoardAdmissionCheck::Unconfigured => {
            freeze_unconfigured_start_admission_in_tx(transaction, &intent_id).await?;
            Ok(TaskBoardFirstStartAdmission::Ready)
        }
        admission => {
            admission.ensure_allowed()?;
            Ok(TaskBoardFirstStartAdmission::Ready)
        }
    }
}

async fn settle_blocked_first_start_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    summary: &str,
    now: &str,
) -> Result<(), CliError> {
    let mut stopped = parent.clone();
    stopped.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    stopped.blocked_reason = Some("first_start_admission_blocked".into());
    stopped.available_at = None;
    stopped.updated_at = now.into();
    stopped.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::HumanRequired,
        summary: summary.into(),
        recorded_at: now.into(),
    });
    validate_task_board_execution_update(parent, &stopped)
        .map_err(|error| db_error(format!("validate blocked first-start execution: {error}")))?;

    let mut cancelled = current_attempt.clone();
    cancelled.state = TaskBoardAttemptState::Cancelled;
    cancelled.failure_class = None;
    cancelled.available_at = None;
    cancelled.error = Some(summary.into());
    cancelled.artifact = None;
    cancelled.updated_at = now.into();
    cancelled.completed_at = Some(now.into());
    validate_task_board_attempt_update(current_attempt, &cancelled)
        .map_err(|error| db_error(format!("validate blocked first-start attempt: {error}")))?;
    validate_attempt_phase(&stopped, &cancelled)?;

    let index = stopped
        .attempts
        .iter()
        .position(|attempt| {
            attempt.action_key == current_attempt.action_key
                && attempt.attempt == current_attempt.attempt
        })
        .ok_or_else(|| db_error("blocked first-start attempt disappeared"))?;
    let mut combined = stopped.clone();
    combined.attempts[index] = cancelled.clone();
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate blocked first-start record: {error}")))?;

    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(parent),
        &stopped,
    )
    .await?;
    update_attempt_in_tx(
        transaction,
        &TaskBoardExecutionAttemptCas::from(current_attempt),
        &cancelled,
    )
    .await?;
    settle_prepared_dispatch_in_tx(transaction, &combined).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(())
}
