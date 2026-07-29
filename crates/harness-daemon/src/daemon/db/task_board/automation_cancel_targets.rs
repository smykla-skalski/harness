use sqlx::{Sqlite, Transaction};

use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, load_assignment_in_tx};
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::CliError;
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE, TaskBoardAttemptState,
    TaskBoardAutomationCancelTarget, TaskBoardExecutionState, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    task_board_remote_execution_target,
};

pub(super) async fn cancel_target_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution_id: &str,
) -> Result<Option<TaskBoardAutomationCancelTarget>, CliError> {
    let Some(parent) = load_execution_in_tx(transaction, execution_id).await? else {
        return Ok(None);
    };
    let Some(assignment_id) = task_board_remote_execution_target(&parent) else {
        return Ok(None);
    };
    let Some(assignment) = load_assignment_in_tx(transaction, assignment_id).await? else {
        return Ok(None);
    };
    Ok(target_from_records(&parent, &assignment))
}

pub(super) fn target_from_records(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Option<TaskBoardAutomationCancelTarget> {
    if !super::exact_active_remote_target(parent, assignment) {
        return None;
    }
    let cancel_pending = parent
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE);
    if assignment.controller_operation.is_some() && !cancel_pending {
        return None;
    }
    let offer = assignment.offer.as_ref()?;
    let attempt = parent.attempts.iter().find(|candidate| {
        candidate.action_key == offer.binding.action_key
            && candidate.attempt == offer.binding.attempt
            && candidate.idempotency_key == offer.binding.idempotency_key
    })?;
    if !safe_state(parent, attempt.state, assignment) {
        return None;
    }
    Some(TaskBoardAutomationCancelTarget {
        execution_id: parent.execution_id.clone(),
        item_id: parent.item_id.clone(),
        workflow_kind: parent.snapshot.workflow_kind,
        assignment_id: assignment.assignment_id.clone(),
        host_id: assignment.host_id.clone(),
        fencing_epoch: assignment.fencing_epoch,
        action_key: offer.binding.action_key.clone(),
        attempt: offer.binding.attempt,
        idempotency_key: offer.binding.idempotency_key.clone(),
        assignment_state: assignment.state.as_str().into(),
        expected_record_sha256: TaskBoardWorkflowExecutionCas::from(parent).record_sha256,
        cancel_pending,
    })
}

fn safe_state(
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt_state: TaskBoardAttemptState,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    matches!(
        assignment.state,
        TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    ) && parent.transition.execution_state == TaskBoardExecutionState::Running
        && attempt_state == TaskBoardAttemptState::Running
}
