use std::future::Future;
use std::pin::Pin;

use sqlx::{Sqlite, Transaction};

use super::items::bump_change_in_tx;
use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, record_controller_handoff_in_tx,
};
use super::remote_assignment_io_authority::{
    active_target_matches, has_remote_io_authority, monotonic_time,
};
use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent};
use super::remote_assignment_status_failure::settle_failed_remote_attempt_in_tx;
use super::workflow_execution_attempts::update_attempt_in_tx;
use super::workflow_executions::update_execution_in_tx;
use super::workflow_terminal::{project_terminal_execution_in_tx, settle_prepared_dispatch_in_tx};
use super::{ITEMS_CHANGE_SCOPE, ORCHESTRATOR_CHANGE_SCOPE};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteStatusResponse,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE,
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_attempt_update,
    validate_task_board_remote_failure_handoff, validate_task_board_remote_result_handoff,
};
use crate::workspace::utc_now;

#[path = "remote_assignment_result_adoption/evidence.rs"]
mod evidence;
use evidence::{load_completed_artifact, require_failed_artifact_set};

#[path = "remote_assignment_result_adoption/screen.rs"]
mod screen;
use screen::{ProceedingAdoption, TerminalAdoptionScreen, screen_terminal_adoption_in_tx};

type SettledAdoptionFuture<'a> = Pin<
    Box<dyn Future<Output = Result<TaskBoardRemoteResultAdoptionOutcome, CliError>> + Send + 'a>,
>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteResultAdoptionOutcome {
    Updated(TaskBoardWorkflowExecutionRecord),
    Replayed(TaskBoardWorkflowExecutionRecord),
    Stale(TaskBoardWorkflowExecutionRecord),
}

impl AsyncDaemonDb {
    pub(crate) async fn adopt_task_board_remote_terminal_result(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<TaskBoardRemoteResultAdoptionOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board remote result adoption")
            .await?;
        match screen_terminal_adoption_in_tx(
            &mut transaction,
            expected,
            assignment_id,
            fencing_epoch,
        )
        .await?
        {
            TerminalAdoptionScreen::Settled { context, outcome } => {
                commit_adoption(transaction, context).await?;
                Ok(outcome)
            }
            TerminalAdoptionScreen::Proceed(proceed) => {
                // The adoption write reaches the result-import evidence loaders
                // through six nested frames, on top of the twenty the calling
                // controller already spends, which puts the closure over the
                // crate's recursion limit and fails the build with `E0275:
                // overflow evaluating the requirement &sqlx::SqliteStatement:
                // Send`. Erasing proves `Send` once for the write half.
                let settled: SettledAdoptionFuture<'_> =
                    Box::pin(settle_screened_adoption(transaction, proceed));
                settled.await
            }
        }
    }
}

/// Write the adoption the screen cleared and settle the transaction that made
/// the handoff, the attempt and the item projection one adoption.
async fn settle_screened_adoption(
    mut transaction: Transaction<'_, Sqlite>,
    proceed: Box<ProceedingAdoption>,
) -> Result<TaskBoardRemoteResultAdoptionOutcome, CliError> {
    let combined = apply_terminal_adoption_in_tx(
        &mut transaction,
        &proceed.assignment,
        &proceed.parent,
        &proceed.current_attempt,
        proceed.attempt_index,
        &utc_now(),
    )
    .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit remote result adoption: {error}")))?;
    Ok(TaskBoardRemoteResultAdoptionOutcome::Updated(combined))
}

async fn apply_terminal_adoption_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    adopted_at: &str,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    let response = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("remote result assignment has no terminal status"))?;
    let handoff = adopt_terminal_handoff_in_tx(
        transaction,
        assignment,
        parent,
        (current_attempt, attempt_index),
        response,
        adopted_at,
    )
    .await?;
    persist_adopted_handoff_in_tx(
        transaction,
        assignment,
        (parent, current_attempt),
        &handoff,
        adopted_at,
    )
    .await?;
    // A terminal parent projects its item, and that projection usually publishes
    // the items change itself; the settled dispatch only owes its own bump when
    // nothing else published one.
    let published = if handoff.terminal_parent {
        let projection = project_terminal_execution_in_tx(transaction, &handoff.combined).await?;
        projection.item_changed || projection.admission_released
    } else {
        false
    };
    if handoff.dispatch_changed && !published {
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    }
    Ok(handoff.combined)
}

/// The workflow and attempt records an adoption writes, whether the combined
/// parent ended up terminal and so needs its item projected, and whether the
/// dispatch settlement that ran first still owes the items scope a bump.
struct AdoptedHandoff {
    combined: TaskBoardWorkflowExecutionRecord,
    updated_attempt: TaskBoardExecutionAttemptRecord,
    terminal_parent: bool,
    dispatch_changed: bool,
}

/// Settle the prepared dispatch, then build the handoff the reported terminal
/// state earns. A completed result reads its artifact first; a failed one proves
/// its artifact set and may leave the parent human-required.
async fn adopt_terminal_handoff_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    (current_attempt, attempt_index): (&TaskBoardExecutionAttemptRecord, usize),
    response: &RemoteStatusResponse,
    adopted_at: &str,
) -> Result<AdoptedHandoff, CliError> {
    let prepared = settle_prepared_dispatch_in_tx(transaction, parent).await?;
    let (combined, updated_attempt, terminal_parent) = match response.state {
        RemoteAssignmentWireState::Completed => {
            let artifact = load_completed_artifact(
                transaction,
                assignment,
                parent,
                current_attempt,
                adopted_at,
            )
            .await?;
            let (combined, attempt) = completed_handoff(
                assignment,
                parent,
                current_attempt,
                attempt_index,
                artifact,
                &response.observed_at,
            )?;
            (combined, attempt, false)
        }
        RemoteAssignmentWireState::Failed => {
            require_failed_artifact_set(transaction, assignment).await?;
            let (combined, attempt) = failed_handoff(
                transaction,
                assignment,
                parent,
                current_attempt,
                attempt_index,
                &response.observed_at,
            )
            .await?;
            let terminal =
                combined.transition.execution_state == TaskBoardExecutionState::HumanRequired;
            (combined, attempt, terminal)
        }
        _ => {
            return Err(db_error(
                "remote result adoption requires completed or failed status",
            ));
        }
    };
    Ok(AdoptedHandoff {
        combined,
        updated_attempt,
        terminal_parent,
        dispatch_changed: prepared.changed,
    })
}

async fn persist_adopted_handoff_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    (parent, current_attempt): (
        &TaskBoardWorkflowExecutionRecord,
        &TaskBoardExecutionAttemptRecord,
    ),
    handoff: &AdoptedHandoff,
    adopted_at: &str,
) -> Result<(), CliError> {
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(parent),
        &handoff.combined,
    )
    .await?;
    update_attempt_in_tx(
        transaction,
        &TaskBoardExecutionAttemptCas::from(current_attempt),
        &handoff.updated_attempt,
    )
    .await?;
    record_controller_handoff_in_tx(
        transaction,
        assignment,
        assignment.state,
        TaskBoardRemoteControllerHandoffKind::ResultAdopted,
        &handoff.combined,
        adopted_at,
    )
    .await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(())
}

async fn commit_adoption(
    transaction: Transaction<'_, Sqlite>,
    disposition: &str,
) -> Result<(), CliError> {
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit {disposition} remote result adoption: {error}"
        ))
    })
}

fn require_active_adoption_target(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(usize, TaskBoardExecutionAttemptRecord), CliError> {
    let offer = assignment.require_offer()?;
    let needs_import = completed_implementation(assignment);
    let authority_ready = if needs_import {
        parent
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
    } else {
        !has_remote_io_authority(parent)
    };
    let authority_free = assignment.controller_operation.is_none()
        && assignment.executor_start_authority_sha256.is_none()
        && assignment.executor_stop_pending.is_none()
        && authority_ready;
    let terminal = matches!(
        assignment.state,
        TaskBoardRemoteAssignmentState::Completed | TaskBoardRemoteAssignmentState::Failed
    );
    let active_parent = matches!(
        parent.transition.execution_state,
        TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
    );
    let attempt = parent.attempts.iter().enumerate().find(|(_, attempt)| {
        attempt.action_key == offer.binding.action_key
            && attempt.attempt == offer.binding.attempt
            && attempt.idempotency_key == offer.binding.idempotency_key
            && matches!(
                attempt.state,
                TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
            )
    });
    if authority_free && terminal && active_parent && active_target_matches(parent, assignment) {
        attempt
            .map(|(index, attempt)| (index, attempt.clone()))
            .ok_or_else(|| concurrent("remote result exact active attempt disappeared"))
    } else {
        Err(concurrent(
            "remote result adoption lost its exact authority-free target",
        ))
    }
}

fn completed_handoff(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    artifact: TaskBoardAttemptResultArtifact,
    observed_at: &str,
) -> Result<
    (
        TaskBoardWorkflowExecutionRecord,
        TaskBoardExecutionAttemptRecord,
    ),
    CliError,
> {
    let settled_at = monotonic_time(&parent.updated_at, observed_at)?;
    let mut completed_attempt = current_attempt.clone();
    let implementation = matches!(artifact, TaskBoardAttemptResultArtifact::Implementation(_));
    completed_attempt.state = TaskBoardAttemptState::Completed;
    completed_attempt.failure_class = None;
    completed_attempt.available_at = None;
    completed_attempt.error = None;
    completed_attempt.artifact = Some(artifact);
    completed_attempt.updated_at = monotonic_time(&current_attempt.updated_at, &settled_at)?;
    completed_attempt.completed_at = Some(completed_attempt.updated_at.clone());
    let mut combined = cleared_remote_target(parent);
    if implementation {
        combined
            .ownership
            .resources
            .remove(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE);
    }
    combined.transition.execution_state = TaskBoardExecutionState::Running;
    combined.available_at = None;
    combined.blocked_reason = None;
    combined.completed_at = None;
    combined.updated_at = settled_at;
    combined.attempts[attempt_index] = completed_attempt.clone();
    validate_task_board_remote_result_handoff(
        parent,
        &combined,
        current_attempt,
        &completed_attempt,
        &assignment.assignment_id,
    )
    .map_err(|error| db_error(format!("validate remote result handoff: {error}")))?;
    Ok((combined, completed_attempt))
}

fn completed_implementation(assignment: &TaskBoardRemoteAssignmentRecord) -> bool {
    assignment.state == TaskBoardRemoteAssignmentState::Completed
        && assignment.phase == TaskBoardExecutionPhase::Implementation
}

async fn failed_handoff(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    observed_at: &str,
) -> Result<
    (
        TaskBoardWorkflowExecutionRecord,
        TaskBoardExecutionAttemptRecord,
    ),
    CliError,
> {
    let response = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("failed remote assignment has no status"))?;
    let settled_at = monotonic_time(&parent.updated_at, observed_at)?;
    let mut combined = parent.clone();
    combined.updated_at.clone_from(&settled_at);
    let mut failed_attempt = current_attempt.clone();
    settle_failed_remote_attempt_in_tx(
        transaction,
        &mut combined,
        &mut failed_attempt,
        response,
        &settled_at,
    )
    .await?;
    clear_remote_target(&mut combined);
    combined.attempts[attempt_index] = failed_attempt.clone();
    validate_task_board_attempt_update(current_attempt, &failed_attempt)
        .map_err(|error| db_error(format!("validate failed remote attempt: {error}")))?;
    validate_task_board_remote_failure_handoff(
        parent,
        &combined,
        current_attempt,
        &failed_attempt,
        &assignment.assignment_id,
    )
    .map_err(|error| db_error(format!("validate remote failure handoff: {error}")))?;
    Ok((combined, failed_attempt))
}

fn cleared_remote_target(
    parent: &TaskBoardWorkflowExecutionRecord,
) -> TaskBoardWorkflowExecutionRecord {
    let mut updated = parent.clone();
    clear_remote_target(&mut updated);
    updated
}

fn clear_remote_target(parent: &mut TaskBoardWorkflowExecutionRecord) {
    parent.ownership.host_id = None;
    parent
        .ownership
        .resources
        .remove(TASK_BOARD_EXECUTION_TARGET_RESOURCE);
    parent
        .ownership
        .resources
        .remove(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE);
    parent
        .ownership
        .resources
        .remove(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE);
}

fn terminal_adoption_replay_matches(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    let Some(offer) = assignment.offer.as_ref() else {
        return false;
    };
    let cleared = parent.ownership.host_id.is_none()
        && parent.ownership.fencing_epoch == assignment.fencing_epoch
        && [
            TASK_BOARD_EXECUTION_TARGET_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
        ]
        .iter()
        .all(|key| !parent.ownership.resources.contains_key(*key));
    let Some(attempt) = parent.attempts.iter().find(|attempt| {
        attempt.action_key == offer.binding.action_key
            && attempt.attempt == offer.binding.attempt
            && attempt.idempotency_key == offer.binding.idempotency_key
    }) else {
        return false;
    };
    let Some(response) = assignment.status_response.as_ref() else {
        return false;
    };
    let adopted = match response.state {
        RemoteAssignmentWireState::Completed => {
            parent.transition.execution_state == TaskBoardExecutionState::Running
                && attempt.state == TaskBoardAttemptState::Completed
                && attempt.artifact.as_ref()
                    == response
                        .result
                        .as_ref()
                        .map(|result| &result.result.artifact)
        }
        RemoteAssignmentWireState::Failed => {
            matches!(
                (parent.transition.execution_state, attempt.state),
                (
                    TaskBoardExecutionState::RetryWait,
                    TaskBoardAttemptState::RetryWait
                ) | (
                    TaskBoardExecutionState::HumanRequired,
                    TaskBoardAttemptState::Failed
                )
            ) && attempt.failure_class == response.failure_class
                && attempt.error == response.error_code
                && attempt.artifact.is_none()
        }
        _ => false,
    };
    cleared && parent.transition.phase == Some(offer.binding.phase) && adopted
}
