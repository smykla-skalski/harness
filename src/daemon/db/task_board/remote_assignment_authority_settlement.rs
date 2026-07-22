use sqlx::{Sqlite, Transaction};

use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, record_controller_handoff_in_tx,
};
use super::remote_assignment_io_authority::{
    TaskBoardRemoteIoAuthorityKind, active_target_matches, authority_resource,
    has_remote_io_authority, monotonic_time, require_authority_parent,
};
use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent};
use super::workflow_execution_attempts::{update_attempt_in_tx, validate_attempt_phase};
use super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use super::workflow_terminal::project_terminal_execution_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{RemoteCancelRequest, RemoteClaimRequest};
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE, TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, validate_task_board_attempt_update,
    validate_task_board_workflow_execution,
};

pub(super) async fn clear_offer_io_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    observed_at: &str,
) -> Result<(), CliError> {
    let offer = assignment.require_offer()?;
    clear_io_authority_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteIoAuthorityKind::Offer,
        &offer.request_sha256,
        observed_at,
    )
    .await
}

pub(super) async fn settle_claim_io_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    claimed_at: &str,
) -> Result<(), CliError> {
    adopt_remote_claim_evidence_in_tx(
        transaction,
        assignment,
        claimed_at,
        Some(&request.request_sha256),
    )
    .await
    .map(|_| ())
}

pub(super) async fn adopt_remote_claim_evidence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    claimed_at: &str,
    authority_digest: Option<&str>,
) -> Result<crate::task_board::TaskBoardWorkflowExecutionRecord, CliError> {
    let parent = claim_parent(transaction, assignment, authority_digest).await?;
    let offer = assignment.require_offer()?;
    let mut active = parent.attempts.iter().enumerate().filter(|(_, attempt)| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    let Some((index, current_attempt)) = active
        .next()
        .map(|(index, attempt)| (index, attempt.clone()))
    else {
        return Err(concurrent("remote claim authority attempt disappeared"));
    };
    if active.next().is_some()
        || current_attempt.action_key != offer.binding.action_key
        || current_attempt.attempt != offer.binding.attempt
        || current_attempt.idempotency_key != offer.binding.idempotency_key
    {
        return Err(concurrent(
            "remote claim evidence does not match one exact active attempt",
        ));
    }
    if current_attempt.state != TaskBoardAttemptState::Starting {
        return Err(concurrent(
            "remote claim authority attempt is no longer starting",
        ));
    }
    let mut running_attempt = current_attempt.clone();
    running_attempt.state = TaskBoardAttemptState::Running;
    running_attempt.updated_at = monotonic_time(&current_attempt.updated_at, claimed_at)?;
    validate_task_board_attempt_update(&current_attempt, &running_attempt)
        .map_err(|error| db_error(format!("validate remote claim attempt: {error}")))?;
    validate_attempt_phase(&parent, &running_attempt)?;
    let mut updated_parent = parent.clone();
    updated_parent.transition.execution_state = TaskBoardExecutionState::Running;
    updated_parent
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE);
    updated_parent.updated_at = monotonic_time(&parent.updated_at, claimed_at)?;
    let mut combined = updated_parent.clone();
    combined.attempts[index] = running_attempt.clone();
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate remote claimed workflow: {error}")))?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(&parent),
        &updated_parent,
    )
    .await?;
    update_attempt_in_tx(
        transaction,
        &TaskBoardExecutionAttemptCas::from(&current_attempt),
        &running_attempt,
    )
    .await?;
    Ok(combined)
}

async fn claim_parent(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority_digest: Option<&str>,
) -> Result<crate::task_board::TaskBoardWorkflowExecutionRecord, CliError> {
    if let Some(digest) = authority_digest {
        return require_authority_parent(
            transaction,
            assignment,
            TaskBoardRemoteIoAuthorityKind::Claim,
            digest,
        )
        .await;
    }
    let parent = load_execution_in_tx(transaction, &assignment.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote claim evidence execution disappeared"))?;
    if has_remote_io_authority(&parent)
        || !active_target_matches(&parent, assignment)
        || parent.transition.execution_state != TaskBoardExecutionState::Starting
    {
        return Err(concurrent(
            "remote claim evidence no longer matches durable workflow state",
        ));
    }
    Ok(parent)
}

pub(super) async fn clear_renew_io_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    digest: &str,
    observed_at: &str,
) -> Result<(), CliError> {
    clear_io_authority_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteIoAuthorityKind::Renew,
        digest,
        observed_at,
    )
    .await
}

pub(super) async fn settle_cancel_io_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
    durable_state: TaskBoardRemoteAssignmentState,
    settled_at: &str,
) -> Result<(), CliError> {
    let parent = require_authority_parent(
        transaction,
        assignment,
        TaskBoardRemoteIoAuthorityKind::Cancel,
        &request.request_sha256,
    )
    .await?;
    project_cancelled_workflow_in_tx(
        transaction,
        assignment,
        request,
        durable_state,
        parent,
        settled_at,
    )
    .await
}

pub(super) async fn project_cancelled_workflow_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
    durable_state: TaskBoardRemoteAssignmentState,
    parent: crate::task_board::TaskBoardWorkflowExecutionRecord,
    settled_at: &str,
) -> Result<(), CliError> {
    let offer = assignment.require_offer()?;
    let Some((index, current_attempt)) = parent
        .attempts
        .iter()
        .enumerate()
        .find(|(_, attempt)| {
            attempt.action_key == offer.binding.action_key
                && attempt.attempt == offer.binding.attempt
                && attempt.idempotency_key == offer.binding.idempotency_key
        })
        .map(|(index, attempt)| (index, attempt.clone()))
    else {
        return Err(concurrent("remote cancel authority attempt disappeared"));
    };
    if !matches!(
        current_attempt.state,
        TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
    ) {
        return Err(concurrent(
            "remote cancel authority attempt is no longer active",
        ));
    }
    let completed_at = monotonic_time(&current_attempt.updated_at, settled_at)?;
    let mut cancelled_attempt = current_attempt.clone();
    cancelled_attempt.state = TaskBoardAttemptState::Cancelled;
    cancelled_attempt.failure_class = None;
    cancelled_attempt.available_at = None;
    cancelled_attempt.error = Some(request.reason.clone());
    cancelled_attempt.artifact = None;
    cancelled_attempt.updated_at.clone_from(&completed_at);
    cancelled_attempt.completed_at = Some(completed_at.clone());
    validate_task_board_attempt_update(&current_attempt, &cancelled_attempt)
        .map_err(|error| db_error(format!("validate remote cancelled attempt: {error}")))?;
    validate_attempt_phase(&parent, &cancelled_attempt)?;
    let mut stopped_parent = parent.clone();
    stopped_parent.transition.execution_state = TaskBoardExecutionState::Cancelled;
    stopped_parent.blocked_reason = None;
    stopped_parent.available_at = None;
    stopped_parent.completed_at = Some(completed_at.clone());
    stopped_parent
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE);
    for resource in [
        TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE,
        TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE,
        TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE,
    ] {
        stopped_parent.ownership.resources.remove(resource);
    }
    stopped_parent.updated_at.clone_from(&completed_at);
    stopped_parent.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Cancelled,
        summary: request.reason.clone(),
        recorded_at: completed_at.clone(),
    });
    let mut combined = stopped_parent.clone();
    combined.attempts[index] = cancelled_attempt.clone();
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate remote cancelled workflow: {error}")))?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(&parent),
        &stopped_parent,
    )
    .await?;
    update_attempt_in_tx(
        transaction,
        &TaskBoardExecutionAttemptCas::from(&current_attempt),
        &cancelled_attempt,
    )
    .await?;
    record_controller_handoff_in_tx(
        transaction,
        assignment,
        durable_state,
        TaskBoardRemoteControllerHandoffKind::TerminalProjection,
        &combined,
        settled_at,
    )
    .await?;
    project_terminal_execution_in_tx(transaction, &combined)
        .await
        .map(|_| ())
}

pub(super) async fn clear_io_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteIoAuthorityKind,
    digest: &str,
    observed_at: &str,
) -> Result<(), CliError> {
    let parent = require_authority_parent(transaction, assignment, kind, digest).await?;
    let mut updated = parent.clone();
    updated.ownership.resources.remove(authority_resource(kind));
    updated.updated_at = monotonic_time(&parent.updated_at, observed_at)?;
    validate_task_board_workflow_execution(&updated)
        .map_err(|error| db_error(format!("validate cleared remote I/O authority: {error}")))?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(&parent),
        &updated,
    )
    .await
}
