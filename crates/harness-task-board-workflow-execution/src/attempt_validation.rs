use harness_kernel::errors::CliError;
use harness_task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardWorkflowExecutionRecord,
};

use crate::support::invalid_transition;

pub(super) fn attempt_replay_matches(
    expected: &TaskBoardExecutionAttemptCas,
    current: &TaskBoardExecutionAttemptRecord,
    updated: &TaskBoardExecutionAttemptRecord,
) -> bool {
    current == updated
        && expected.execution_id == current.execution_id
        && expected.action_key == current.action_key
        && expected.attempt == current.attempt
        && expected.idempotency_key == current.idempotency_key
}

/// Confirms an attempt and any completed artifact belong to the execution's active phase.
///
/// # Errors
/// Returns [`CliError`] when the attempt contradicts the execution or its active phase.
pub fn validate_attempt_phase(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    if attempt.execution_id != execution.execution_id {
        return Err(invalid_transition(
            "workflow attempt does not belong to its execution",
        ));
    }
    let phase = execution
        .transition
        .phase
        .ok_or_else(|| invalid_transition("workflow execution has no active phase"))?;
    let valid_action = match phase {
        TaskBoardExecutionPhase::Implementation => {
            (execution
                .snapshot
                .workflow_kind
                .has_dependency_update_intent()
                && execution.artifacts.dependency_triage.is_none()
                && attempt.action_key == "dependency_triage")
                || attempt.action_key
                    == format!(
                        "implementation:{}",
                        execution.artifacts.current_revision_cycle
                    )
        }
        TaskBoardExecutionPhase::Review => attempt.action_key.starts_with("review:"),
        TaskBoardExecutionPhase::Evaluate => {
            attempt.action_key == "evaluate"
                || attempt.action_key
                    == format!("evaluate:{}", execution.artifacts.current_revision_cycle)
        }
        TaskBoardExecutionPhase::Publish => attempt.action_key == "publish",
        TaskBoardExecutionPhase::Cleanup => attempt.action_key == "cleanup",
        TaskBoardExecutionPhase::Planning
        | TaskBoardExecutionPhase::AwaitingApproval
        | TaskBoardExecutionPhase::Terminal => false,
    };
    if !valid_action {
        return Err(invalid_transition(format!(
            "workflow attempt action '{}' does not belong to phase {phase:?} at revision cycle {}",
            attempt.action_key, execution.artifacts.current_revision_cycle
        )));
    }
    if attempt.state != TaskBoardAttemptState::Completed {
        return Ok(());
    }
    let valid_artifact = match (phase, attempt.artifact.as_ref()) {
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
    if valid_artifact {
        Ok(())
    } else {
        Err(invalid_transition(
            "workflow attempt result artifact contradicts its frozen phase",
        ))
    }
}
