use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
    record_controller_handoff_in_tx,
};
use super::remote_assignment_authority_settlement::clear_offer_io_authority_in_tx;
use super::remote_assignment_io_authority::{active_target_matches, monotonic_time};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, load_assignment_in_tx, to_i64,
};
use super::remote_assignment_rejection::apply_unclaimable_offer_in_tx;
use super::workflow_execution_attempts::update_attempt_in_tx;
use super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use super::workflow_terminal::project_terminal_execution_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE, TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE, TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardRemoteAssignmentState,
    TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_attempt_update,
    validate_task_board_workflow_execution,
};

const UNKNOWN_REASON: &str = "remote assignment outcome is unknown after lease or deadline expiry";

pub(super) async fn recover_controller_remote_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    now: &str,
) -> Result<bool, CliError> {
    let current = load_assignment_in_tx(transaction, &assignment.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote assignment recovery generation disappeared"))?;
    require_same_generation(assignment, &current)?;
    let assignment = &current;
    let Some(parent) = load_execution_in_tx(transaction, &assignment.execution_id).await? else {
        return supersede_detached_controller_assignment_in_tx(transaction, assignment, now).await;
    };
    if parent_is_terminal_or_non_remote(&parent, assignment) {
        return supersede_detached_controller_assignment_in_tx(transaction, assignment, now).await;
    }
    let offer_authority = parent
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE);
    let claim_authority = parent
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE);
    let cancel_authority = parent
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE);
    if assignment.state == TaskBoardRemoteAssignmentState::Offered
        && !claim_authority
        && !cancel_authority
    {
        if offer_authority {
            clear_offer_io_authority_in_tx(transaction, assignment, now).await?;
        }
        return apply_unclaimable_offer_in_tx(
            transaction,
            assignment,
            "remote offer expired before durable claim",
            now,
        )
        .await?
        .map(|_| true)
        .ok_or_else(|| concurrent("expired remote offer lost its local fallback fence"));
    }
    recover_ambiguous_remote_start_in_tx(transaction, assignment, &parent, now).await
}

fn require_same_generation(
    expected: &TaskBoardRemoteAssignmentRecord,
    current: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    if expected.fencing_epoch == current.fencing_epoch
        && expected.execution_id == current.execution_id
        && expected.request_sha256 == current.request_sha256
    {
        Ok(())
    } else {
        Err(concurrent(
            "remote assignment recovery generation changed before settlement",
        ))
    }
}

fn parent_is_terminal_or_non_remote(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let terminal = matches!(
        parent.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
            | TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    );
    let reconciliable_unknown = assignment.state == TaskBoardRemoteAssignmentState::Unknown
        && parent.transition.execution_state == TaskBoardExecutionState::HumanRequired
        && parent.blocked_reason.as_deref() == Some("remote_assignment_outcome_unknown")
        && active_target_matches(parent, assignment);
    let target = parent
        .ownership
        .resources
        .get(crate::task_board::TASK_BOARD_EXECUTION_TARGET_RESOURCE);
    let non_remote = target.is_none_or(|value| !value.starts_with("remote:"));
    (terminal && !reconciliable_unknown) || non_remote
}

async fn supersede_detached_controller_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    now: &str,
) -> Result<bool, CliError> {
    if assignment.state == TaskBoardRemoteAssignmentState::Superseded {
        return Ok(false);
    }
    let updated_at = monotonic_time(&assignment.updated_at, now)?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'superseded',
         completed_at = ?2, result_json = NULL, status_sha256 = NULL,
         result_sha256 = NULL,
         error = 'remote assignment parent terminalized or changed target', updated_at = ?2
         WHERE assignment_id = ?1 AND fencing_epoch = ?3 AND state = ?4
           AND updated_at = ?5 AND request_sha256 IS ?6 AND lease_id IS ?7",
    )
    .bind(&assignment.assignment_id)
    .bind(updated_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "detached remote recovery fencing epoch",
    )?)
    .bind(assignment.state.as_str())
    .bind(&assignment.updated_at)
    .bind(&assignment.request_sha256)
    .bind(&assignment.lease_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("supersede detached controller assignment: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(true)
    } else {
        Err(concurrent(
            "detached controller assignment lost its exact generation fence",
        ))
    }
}

pub(super) async fn recover_ambiguous_remote_start_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<bool, CliError> {
    if evidence_only_unknown_recovery_replays_in_tx(transaction, assignment, parent).await? {
        return Ok(false);
    }
    if !active_target_matches(parent, assignment) {
        return Err(concurrent(
            "remote recovery target diverged from assignment",
        ));
    }
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
        return Err(concurrent("remote recovery attempt disappeared"));
    };
    if !matches!(
        current_attempt.state,
        TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
    ) {
        return Err(concurrent("remote recovery attempt is not active"));
    }
    let unknown_attempt = unknown_attempt(&current_attempt, now)?;
    let mut stopped_parent = parent.clone();
    stopped_parent.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    stopped_parent.blocked_reason = Some("remote_assignment_outcome_unknown".into());
    stopped_parent.available_at = None;
    stopped_parent
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE);
    stopped_parent
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE);
    stopped_parent
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE);
    stopped_parent
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE);
    stopped_parent.updated_at = monotonic_time(&parent.updated_at, now)?;
    stopped_parent.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Unknown,
        summary: UNKNOWN_REASON.into(),
        recorded_at: now.into(),
    });
    let mut combined = stopped_parent.clone();
    combined.attempts[index] = unknown_attempt.clone();
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate recovered remote workflow: {error}")))?;
    mark_assignment_unknown_in_tx(transaction, assignment, now).await?;
    record_controller_handoff_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteAssignmentState::Unknown,
        TaskBoardRemoteControllerHandoffKind::EvidenceOnly,
        &combined,
        now,
    )
    .await?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(parent),
        &stopped_parent,
    )
    .await?;
    update_attempt_in_tx(
        transaction,
        &TaskBoardExecutionAttemptCas::from(&current_attempt),
        &unknown_attempt,
    )
    .await?;
    project_terminal_execution_in_tx(transaction, &combined).await?;
    Ok(true)
}

async fn evidence_only_unknown_recovery_replays_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    if assignment.state != TaskBoardRemoteAssignmentState::Unknown
        || parent.transition.execution_state != TaskBoardExecutionState::HumanRequired
        || parent.blocked_reason.as_deref() != Some("remote_assignment_outcome_unknown")
        || super::remote_assignment_io_authority::has_remote_io_authority(parent)
    {
        return Ok(false);
    }
    controller_handoff_matches_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteControllerHandoffKind::EvidenceOnly,
        parent,
    )
    .await
}

fn unknown_attempt(
    current: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<TaskBoardExecutionAttemptRecord, CliError> {
    let mut unknown = current.clone();
    unknown.state = TaskBoardAttemptState::Unknown;
    unknown.failure_class = Some(TaskBoardFailureClass::UnknownOutcome);
    unknown.available_at = None;
    unknown.error = Some(UNKNOWN_REASON.into());
    unknown.artifact = None;
    unknown.updated_at = monotonic_time(&current.updated_at, now)?;
    validate_task_board_attempt_update(current, &unknown)
        .map_err(|error| db_error(format!("validate recovered remote attempt: {error}")))?;
    Ok(unknown)
}

async fn mark_assignment_unknown_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    now: &str,
) -> Result<(), CliError> {
    if assignment.state == TaskBoardRemoteAssignmentState::Unknown {
        return Ok(());
    }
    let updated_at = monotonic_time(&assignment.updated_at, now)?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'unknown',
         result_json = NULL, status_sha256 = NULL, result_sha256 = NULL,
         error = ?2, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?4
           AND state IN ('offered', 'claimed', 'started', 'running')",
    )
    .bind(&assignment.assignment_id)
    .bind(UNKNOWN_REASON)
    .bind(updated_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote recovery fencing epoch",
    )?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("mark controller remote outcome unknown: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "controller remote recovery lost its assignment fence",
        ))
    }
}
