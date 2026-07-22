use super::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_RESOURCE,
    exact_attempt, invalid, parse_target_attempt, required_target, target_identity,
    validate_target_update,
};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowExecutionValidationError,
};

pub const TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE: &str = "legacy_local_target_adoption";
pub const TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43: &str = "v43_migrated";
pub const TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE: &str = "legacy_local_target_action_key";
pub const TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE: &str = "legacy_local_target_attempt";
pub const TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE: &str =
    "legacy_local_target_idempotency_key";

/// Validate the one-time local target adoption for a migrated targetless Starting attempt.
///
/// # Errors
///
/// Returns an error unless the current execution carries the exact migration-bound action,
/// attempt, and idempotency marker and the update consumes it while advancing that child.
pub fn validate_task_board_legacy_local_target_adoption(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if !matches!(
        current.transition.execution_state,
        TaskBoardExecutionState::Pending
            | TaskBoardExecutionState::Starting
            | TaskBoardExecutionState::Running
    ) || updated.transition.execution_state != TaskBoardExecutionState::Starting
        || current
            .ownership
            .resources
            .get(TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE)
            .map(String::as_str)
            != Some(TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43)
        || target_identity(current)?.is_some()
        || required_target(updated, TASK_BOARD_EXECUTION_TARGET_RESOURCE)? != "local"
    {
        return invalid(
            "ownership.resources",
            "legacy local target adoption requires a supported targetless execution",
        );
    }
    let action = required_target(updated, TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)?;
    let attempt = parse_target_attempt(updated)?;
    let current_attempt = exact_attempt(current, action, attempt)?;
    let marker_matches = required_target(current, TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE)?
        == action
        && required_target(current, TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE)?
            .parse::<u32>()
            .ok()
            == Some(attempt)
        && required_target(current, TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE)?
            == current_attempt.idempotency_key
        && legacy_marker_keys()
            .iter()
            .all(|key| !updated.ownership.resources.contains_key(*key));
    if current_attempt.state != TaskBoardAttemptState::Starting || !marker_matches {
        return invalid(
            "ownership.resources",
            "legacy local target adoption requires the exact one-shot Starting attempt marker",
        );
    }
    validate_target_update(current, updated, true)
}

const fn legacy_marker_keys() -> [&'static str; 4] {
    [
        TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE,
    ]
}
