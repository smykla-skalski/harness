use super::super::workflow_executions::{
    ensure_terminal_transition_has_no_active_side_effect, validate_phase_change,
};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardWorkflowExecutionRecord,
    validate_task_board_attempt_update, validate_task_board_execution_update,
    validate_task_board_workflow_execution,
};

pub(crate) fn validate_atomic_execution_attempt_update(
    current: &TaskBoardWorkflowExecutionRecord,
    updated_execution: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    updated_attempt: &TaskBoardExecutionAttemptRecord,
    combined: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    ensure_terminal_transition_has_no_active_side_effect(current, updated_execution)?;
    validate_task_board_execution_update(current, updated_execution)
        .map_err(|error| db_error(format!("validate atomic workflow execution CAS: {error}")))?;
    validate_phase_change(current, updated_execution)?;
    validate_task_board_attempt_update(current_attempt, updated_attempt)
        .map_err(|error| db_error(format!("validate atomic execution attempt CAS: {error}")))?;
    validate_attempt_phase(combined, updated_attempt)?;
    ensure_external_side_effect_uses_atomic_claim(current, current_attempt, updated_attempt)?;
    validate_task_board_workflow_execution(combined)
        .map_err(|error| db_error(format!("validate combined workflow execution CAS: {error}")))
}

pub(crate) fn attempt_cas_matches(
    expected: &TaskBoardExecutionAttemptCas,
    current: &TaskBoardExecutionAttemptRecord,
) -> bool {
    attempt_identity_matches(expected, current) && expected.state == current.state
}

pub(crate) fn attempt_identity_matches(
    expected: &TaskBoardExecutionAttemptCas,
    current: &TaskBoardExecutionAttemptRecord,
) -> bool {
    expected.execution_id == current.execution_id
        && expected.action_key == current.action_key
        && expected.attempt == current.attempt
        && expected.idempotency_key == current.idempotency_key
}

pub(super) fn validate_attempt_in_execution(
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    replace_index: Option<usize>,
) -> Result<(), CliError> {
    let mut candidate = parent.clone();
    if let Some(index) = replace_index {
        candidate.attempts[index] = attempt.clone();
    } else {
        candidate.attempts.push(attempt.clone());
    }
    validate_task_board_workflow_execution(&candidate)
        .map_err(|error| db_error(format!("validate attempt in durable execution: {error}")))
}

pub(crate) fn validate_attempt_phase(
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    if attempt.execution_id != parent.execution_id {
        return Err(db_error(
            "workflow attempt does not belong to its execution",
        ));
    }
    let phase = parent
        .transition
        .phase
        .ok_or_else(|| db_error("workflow execution has no active phase"))?;
    let valid_action = match phase {
        TaskBoardExecutionPhase::Implementation => {
            (parent.snapshot.workflow_kind.has_dependency_update_intent()
                && parent.artifacts.dependency_triage.is_none()
                && attempt.action_key == "dependency_triage")
                || attempt.action_key
                    == format!("implementation:{}", parent.artifacts.current_revision_cycle)
        }
        TaskBoardExecutionPhase::Review => attempt.action_key.starts_with("review:"),
        TaskBoardExecutionPhase::Evaluate => {
            attempt.action_key == "evaluate"
                || attempt.action_key
                    == format!("evaluate:{}", parent.artifacts.current_revision_cycle)
        }
        TaskBoardExecutionPhase::Publish => attempt.action_key == "publish",
        TaskBoardExecutionPhase::Cleanup => attempt.action_key == "cleanup",
        TaskBoardExecutionPhase::Planning
        | TaskBoardExecutionPhase::AwaitingApproval
        | TaskBoardExecutionPhase::Terminal => false,
    };
    if !valid_action {
        return Err(db_error(format!(
            "workflow attempt action '{}' does not belong to phase {phase:?}",
            attempt.action_key
        )));
    }
    validate_completed_artifact(phase, attempt)
}

pub(super) fn ensure_external_side_effect_uses_atomic_claim(
    parent: &TaskBoardWorkflowExecutionRecord,
    current: &TaskBoardExecutionAttemptRecord,
    updated: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    let external_claim = matches!(
        parent.transition.phase,
        Some(
            TaskBoardExecutionPhase::Review
                | TaskBoardExecutionPhase::Implementation
                | TaskBoardExecutionPhase::Evaluate
                | TaskBoardExecutionPhase::Publish
        )
    ) && (parent.transition.phase != Some(TaskBoardExecutionPhase::Publish)
        || current.action_key == "publish")
        && current.state == TaskBoardAttemptState::Starting
        && updated.state == TaskBoardAttemptState::Running;
    if external_claim {
        Err(db_error(
            "workflow external side-effect requires an atomic parent and attempt claim",
        ))
    } else {
        Ok(())
    }
}

pub(super) fn validate_completed_artifact(
    phase: TaskBoardExecutionPhase,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    if attempt.state != TaskBoardAttemptState::Completed {
        return Ok(());
    }
    let valid = match (phase, attempt.artifact.as_ref()) {
        (
            TaskBoardExecutionPhase::Implementation,
            Some(TaskBoardAttemptResultArtifact::DependencyTriage(_)),
        ) => attempt.action_key == "dependency_triage",
        (
            TaskBoardExecutionPhase::Implementation,
            Some(TaskBoardAttemptResultArtifact::Implementation(_)),
        ) => attempt.action_key.starts_with("implementation:"),
        (
            TaskBoardExecutionPhase::Evaluate,
            Some(TaskBoardAttemptResultArtifact::Evaluation(_)),
        )
        | (
            TaskBoardExecutionPhase::Publish | TaskBoardExecutionPhase::Cleanup,
            Some(TaskBoardAttemptResultArtifact::Lifecycle(_)),
        ) => true,
        (
            TaskBoardExecutionPhase::Review,
            Some(TaskBoardAttemptResultArtifact::Review(outcome)),
        ) => attempt.action_key == format!("review:{}", outcome.profile_id),
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(db_error(
            "workflow attempt result artifact contradicts its frozen phase",
        ))
    }
}
