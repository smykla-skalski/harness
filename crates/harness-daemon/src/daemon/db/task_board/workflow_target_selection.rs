use sqlx::{Sqlite, Transaction};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_active_fence::active_remote_assignment_exists_in_tx;
use super::workflow_execution_attempts::{
    attempt_cas_matches, update_attempt_in_tx, validate_attempt_phase,
};
use super::workflow_executions::{cas_mismatch, load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    validate_task_board_attempt_update, validate_task_board_execution_target_update,
    validate_task_board_workflow_execution,
};

impl AsyncDaemonDb {
    /// Selects the exact local target before any local runtime side effect is claimable.
    pub(crate) async fn select_task_board_local_execution_target(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        selected_at: &str,
    ) -> Result<bool, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board local execution target selection")
            .await?;
        let (parent, attempt_index) = match screen_local_execution_target_in_tx(
            &mut transaction,
            expected_execution,
            expected_attempt,
        )
        .await?
        {
            LocalTargetScreen::Stopped => return commit_noop(transaction).await,
            LocalTargetScreen::Ready(parent, attempt_index) => (parent, attempt_index),
        };
        write_local_execution_target_in_tx(
            &mut transaction,
            expected_execution,
            expected_attempt,
            &parent,
            attempt_index,
            selected_at,
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board local target selection: {error}"))
        })?;
        Ok(true)
    }
}

/// Either the parent, the exact attempt, or the attempt's eligibility is
/// already stale and the caller has nothing left but to commit the no-op, or
/// the exact parent and attempt index are ready for the local target write.
enum LocalTargetScreen {
    Stopped,
    Ready(Box<TaskBoardWorkflowExecutionRecord>, usize),
}

async fn screen_local_execution_target_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
) -> Result<LocalTargetScreen, CliError> {
    let Some(parent) = load_execution_in_tx(transaction, &expected_execution.execution_id).await?
    else {
        return Ok(LocalTargetScreen::Stopped);
    };
    let Some((attempt_index, attempt)) =
        parent.attempts.iter().enumerate().find(|(_, candidate)| {
            candidate.action_key == expected_attempt.action_key
                && candidate.attempt == expected_attempt.attempt
        })
    else {
        return Ok(LocalTargetScreen::Stopped);
    };
    if local_target_is_stale_in_tx(
        transaction,
        expected_execution,
        expected_attempt,
        &parent,
        attempt,
    )
    .await?
    {
        return Ok(LocalTargetScreen::Stopped);
    }
    Ok(LocalTargetScreen::Ready(Box::new(parent), attempt_index))
}

/// Builds and writes the local target claim onto the execution and its
/// attempt, then bumps the change ledger.
async fn write_local_execution_target_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt_index: usize,
    selected_at: &str,
) -> Result<(), CliError> {
    let attempt = &parent.attempts[attempt_index];
    let (updated_parent, updated_attempt) =
        build_local_target(parent, attempt, attempt_index, selected_at)?;
    update_execution_in_tx(transaction, expected_execution, &updated_parent).await?;
    update_attempt_in_tx(transaction, expected_attempt, &updated_attempt).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(())
}

/// Whether this exact attempt is no longer eligible for a local target: its
/// CAS moved, its phase cannot select locally, or a remote assignment already
/// claimed the execution.
async fn local_target_is_stale_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<bool, CliError> {
    if cas_mismatch(expected_execution, parent).is_some()
        || !attempt_cas_matches(expected_attempt, attempt)
        || attempt.state != TaskBoardAttemptState::Preparing
        || !remotely_selectable(parent.transition.phase)
    {
        return Ok(true);
    }
    active_remote_assignment_exists_in_tx(transaction, &expected_execution.execution_id).await
}

fn build_local_target(
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    selected_at: &str,
) -> Result<
    (
        TaskBoardWorkflowExecutionRecord,
        TaskBoardExecutionAttemptRecord,
    ),
    CliError,
> {
    let mut selected_attempt = attempt.clone();
    selected_attempt.state = TaskBoardAttemptState::Starting;
    selected_attempt.available_at = None;
    selected_at.clone_into(&mut selected_attempt.updated_at);
    validate_task_board_attempt_update(attempt, &selected_attempt)
        .map_err(|error| db_error(format!("validate local target attempt: {error}")))?;
    validate_attempt_phase(parent, &selected_attempt)?;

    let mut selected_parent = parent.clone();
    selected_parent.transition.execution_state = TaskBoardExecutionState::Starting;
    selected_parent.ownership.host_id = None;
    selected_parent
        .ownership
        .resources
        .insert(TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(), "local".into());
    selected_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE.into(),
        selected_attempt.action_key.clone(),
    );
    selected_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE.into(),
        selected_attempt.attempt.to_string(),
    );
    selected_parent.available_at = None;
    selected_parent.blocked_reason = None;
    selected_at.clone_into(&mut selected_parent.updated_at);
    let mut combined = selected_parent.clone();
    combined.attempts[attempt_index].clone_from(&selected_attempt);
    validate_task_board_execution_target_update(parent, &combined)
        .map_err(|error| db_error(format!("validate local target selection: {error}")))?;
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate local target execution: {error}")))?;
    Ok((selected_parent, selected_attempt))
}

const fn remotely_selectable(phase: Option<TaskBoardExecutionPhase>) -> bool {
    matches!(
        phase,
        Some(
            TaskBoardExecutionPhase::Implementation
                | TaskBoardExecutionPhase::Review
                | TaskBoardExecutionPhase::Evaluate
        )
    )
}

async fn commit_noop(transaction: Transaction<'_, Sqlite>) -> Result<bool, CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit stale local target selection: {error}")))?;
    Ok(false)
}
