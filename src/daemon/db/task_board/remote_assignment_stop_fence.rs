use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_cancel_journal::{cancel_intent_request_for_record, cancel_request};
use super::remote_assignment_io_authority::{active_target_matches, monotonic_time};
use super::remote_assignment_model::{concurrent, load_assignment_in_tx, to_i64};
use super::remote_operation_trust::has_controller_operation_trust;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE,
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowExecutionRecord, validate_task_board_workflow_execution,
};

pub(super) enum RemoteTargetStopPlan {
    ApplyRequested,
    PersistCancelIntent(TaskBoardWorkflowExecutionRecord),
    ReplayedCancelIntent(TaskBoardWorkflowExecutionRecord),
}

pub(super) async fn remote_target_stop_plan_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<RemoteTargetStopPlan, CliError> {
    if !stops(current, updated) {
        return Ok(RemoteTargetStopPlan::ApplyRequested);
    }
    let Some(assignment_id) = current
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        .and_then(|target| target.strip_prefix("remote:"))
    else {
        return Ok(RemoteTargetStopPlan::ApplyRequested);
    };
    let assignment = load_assignment_in_tx(transaction, assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote workflow target assignment disappeared"))?;
    if !active_target_matches(current, &assignment) {
        return Err(concurrent("remote workflow target assignment diverged"));
    }
    if has_controller_operation_trust(&assignment) {
        return Err(concurrent(
            "remote workflow has an in-flight controller operation",
        ));
    }
    if assignment.state == TaskBoardRemoteAssignmentState::Superseded
        && assignment.claimed_at.is_none()
    {
        return Ok(RemoteTargetStopPlan::ApplyRequested);
    }
    if matches!(
        assignment.state,
        TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    ) {
        return deferred_cancel_plan(current, updated, &assignment);
    }
    if assignment.state != TaskBoardRemoteAssignmentState::Offered
        || assignment.claimed_at.is_some()
    {
        return Err(concurrent(
            "remote workflow target cannot be stopped safely",
        ));
    }
    let stopped_at = updated
        .completed_at
        .as_deref()
        .unwrap_or(&updated.updated_at);
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'superseded',
         heartbeat_at = ?2, completed_at = ?2,
         error = 'workflow stopped before remote claim', updated_at = ?2
         WHERE assignment_id = ?1 AND fencing_epoch = ?3
           AND state = 'offered' AND claimed_at IS NULL",
    )
    .bind(&assignment.assignment_id)
    .bind(stopped_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "assignment fencing epoch",
    )?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("supersede stopped remote assignment: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(RemoteTargetStopPlan::ApplyRequested)
    } else {
        Err(concurrent("stopped remote assignment lost its fence"))
    }
}

pub(super) fn remote_stop_requires_cancellation(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    stops(current, updated)
        && current.transition.execution_state == TaskBoardExecutionState::Running
        && current
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.strip_prefix("remote:").is_some())
        && exact_running_target_attempt(current)
}

fn deferred_cancel_plan(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
    assignment: &super::remote_assignment_model::TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteTargetStopPlan, CliError> {
    if !remote_stop_requires_cancellation(current, updated) {
        return Err(concurrent(
            "remote cancellation requires the exact running target attempt",
        ));
    }
    let reason = cancel_reason(updated);
    let requested_at = updated
        .completed_at
        .as_deref()
        .unwrap_or(updated.updated_at.as_str());
    let request = cancel_request(assignment, reason)?;
    if let Some(existing) = cancel_intent_request_for_record(current, assignment)? {
        let exact_time = current
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE)
            .is_some_and(|value| value == requested_at);
        return if existing == request && exact_time {
            Ok(RemoteTargetStopPlan::ReplayedCancelIntent(current.clone()))
        } else {
            Err(concurrent(
                "remote cancel intent conflicts with the requested terminal transition",
            ))
        };
    }
    let mut intent_parent = current.clone();
    intent_parent.ownership.resources.insert(
        TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE.into(),
        request.request_sha256,
    );
    intent_parent.ownership.resources.insert(
        TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE.into(),
        request.reason,
    );
    intent_parent.ownership.resources.insert(
        TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE.into(),
        requested_at.into(),
    );
    intent_parent.updated_at = monotonic_time(&current.updated_at, requested_at)?;
    validate_task_board_workflow_execution(&intent_parent)
        .map_err(|error| db_error(format!("validate remote cancel intent: {error}")))?;
    Ok(RemoteTargetStopPlan::PersistCancelIntent(intent_parent))
}

fn exact_running_target_attempt(parent: &TaskBoardWorkflowExecutionRecord) -> bool {
    let action = parent
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE);
    let attempt = parent
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
        .and_then(|value| value.parse::<u32>().ok());
    let mut active = parent.attempts.iter().filter(|candidate| {
        matches!(
            candidate.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    action.zip(attempt).is_some_and(|(action, attempt)| {
        active.next().is_some_and(|candidate| {
            candidate.action_key == action.as_str()
                && candidate.attempt == attempt
                && candidate.state == TaskBoardAttemptState::Running
        }) && active.next().is_none()
    })
}

fn cancel_reason(updated: &TaskBoardWorkflowExecutionRecord) -> &str {
    updated
        .artifacts
        .terminal_outcome
        .as_ref()
        .map(|outcome| outcome.summary.as_str())
        .or(updated.blocked_reason.as_deref())
        .unwrap_or("workflow stop requested")
}

fn stops(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    !terminal(current.transition.execution_state) && terminal(updated.transition.execution_state)
}

const fn terminal(state: TaskBoardExecutionState) -> bool {
    matches!(
        state,
        TaskBoardExecutionState::HumanRequired
            | TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    )
}
