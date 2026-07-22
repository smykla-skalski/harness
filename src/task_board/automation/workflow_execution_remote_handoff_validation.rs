use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE,
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionState,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowExecutionValidationError,
    validate_task_board_attempt_update, validate_task_board_execution_update,
    validate_task_board_workflow_execution,
};

pub(crate) fn validate_task_board_remote_result_handoff(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    completed_attempt: &TaskBoardExecutionAttemptRecord,
    assignment_id: &str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let expected_target = format!("remote:{assignment_id}");
    let exact_current_target = current
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        == Some(&expected_target)
        && current
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == Some(&current_attempt.action_key)
        && current
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .is_some_and(|value| value == &current_attempt.attempt.to_string())
        && current.ownership.host_id.is_some()
        && matches!(
            current.transition.execution_state,
            TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
        )
        && matches!(
            current_attempt.state,
            TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
        );
    if !exact_current_target {
        return invalid("remote handoff does not own the exact active attempt");
    }
    let target_cleared = updated.ownership.host_id.is_none()
        && updated.ownership.fencing_epoch == current.ownership.fencing_epoch
        && [
            TASK_BOARD_EXECUTION_TARGET_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
        ]
        .iter()
        .all(|key| !updated.ownership.resources.contains_key(*key));
    if !target_cleared || non_target_resources_changed(current, updated) {
        return invalid("remote handoff changed ownership beyond the exact target");
    }
    if updated.transition.execution_state != TaskBoardExecutionState::Running
        || completed_attempt.state != TaskBoardAttemptState::Completed
    {
        return invalid("remote handoff must expose one completed coordinator result");
    }
    validate_task_board_attempt_update(current_attempt, completed_attempt)?;
    let mut ordinary = updated.clone();
    ordinary.ownership.clone_from(&current.ownership);
    ordinary.attempts.clone_from(&current.attempts);
    validate_task_board_execution_update(current, &ordinary)?;
    validate_task_board_workflow_execution(updated)
}

pub(crate) fn validate_task_board_remote_failure_handoff(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    settled_attempt: &TaskBoardExecutionAttemptRecord,
    assignment_id: &str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let expected_target = format!("remote:{assignment_id}");
    let exact_current_target = current
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        == Some(&expected_target)
        && current
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == Some(&current_attempt.action_key)
        && current
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .is_some_and(|value| value == &current_attempt.attempt.to_string())
        && current.ownership.host_id.is_some()
        && matches!(
            current.transition.execution_state,
            TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
        )
        && matches!(
            current_attempt.state,
            TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
        );
    if !exact_current_target {
        return invalid("remote failure handoff does not own the exact active attempt");
    }
    let target_cleared = updated.ownership.host_id.is_none()
        && updated.ownership.fencing_epoch == current.ownership.fencing_epoch
        && [
            TASK_BOARD_EXECUTION_TARGET_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
        ]
        .iter()
        .all(|key| !updated.ownership.resources.contains_key(*key));
    let paired_state = matches!(
        (updated.transition.execution_state, settled_attempt.state),
        (
            TaskBoardExecutionState::RetryWait,
            TaskBoardAttemptState::RetryWait
        ) | (
            TaskBoardExecutionState::HumanRequired,
            TaskBoardAttemptState::Failed
        )
    );
    if !target_cleared || non_target_resources_changed(current, updated) || !paired_state {
        return invalid("remote failure handoff changed evidence beyond its retry outcome");
    }
    validate_task_board_attempt_update(current_attempt, settled_attempt)?;
    let mut ordinary = updated.clone();
    ordinary.ownership.clone_from(&current.ownership);
    ordinary.attempts.clone_from(&current.attempts);
    validate_task_board_execution_update(current, &ordinary)?;
    validate_task_board_workflow_execution(updated)
}

fn non_target_resources_changed(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    let mut expected = current.ownership.resources.clone();
    expected.remove(TASK_BOARD_EXECUTION_TARGET_RESOURCE);
    expected.remove(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE);
    expected.remove(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE);
    // A completed-implementation adoption consumes the result-import authority as
    // part of the same handoff, so its removal is expected, not an escape. Failure
    // and review handoffs never carry this key, so dropping it is a no-op there.
    expected.remove(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE);
    expected != updated.ownership.resources
}

fn invalid(detail: &'static str) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    Err(TaskBoardWorkflowExecutionValidationError::InvalidField {
        field: "ownership.remote_result_handoff",
        detail: detail.into(),
    })
}
