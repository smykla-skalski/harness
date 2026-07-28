use crate::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardLocalAttemptResult,
    TaskBoardWorkflowExecutionRecord,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TaskBoardLocalAttemptResultExpectation<'a> {
    pub execution_id: &'a str,
    pub action_key: &'a str,
    pub attempt: u32,
    pub idempotency_key: &'a str,
    pub artifact: TaskBoardAttemptResultArtifactExpectation<'a>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskBoardAttemptResultArtifactExpectation<'a> {
    Implementation {
        revision_cycle: u32,
        base_head_revision: &'a str,
    },
    Review {
        profile_id: &'a str,
        head_revision: &'a str,
    },
    Evaluation {
        exact_head_revision: &'a str,
        head_revision: Option<&'a str>,
        revision_cycle: Option<u32>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskBoardLocalAttemptResultValidationError {
    IdentityMismatch,
    ArtifactMismatch,
}

/// Derive the local attempt result this attempt's phase must satisfy.
///
/// # Errors
/// Returns [`TaskBoardLocalAttemptResultValidationError::ArtifactMismatch`] if
/// the execution has no exact head revision or is not in a phase that
/// produces a local attempt result.
pub fn task_board_local_attempt_result_expectation<'a>(
    execution: &'a TaskBoardWorkflowExecutionRecord,
    attempt: &'a TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardLocalAttemptResultExpectation<'a>, TaskBoardLocalAttemptResultValidationError>
{
    let head = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or(TaskBoardLocalAttemptResultValidationError::ArtifactMismatch)?;
    let cycle = execution.artifacts.current_revision_cycle;
    let artifact = match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Implementation) => {
            TaskBoardAttemptResultArtifactExpectation::Implementation {
                revision_cycle: cycle,
                base_head_revision: head,
            }
        }
        Some(TaskBoardExecutionPhase::Review) => {
            let profile_id = attempt
                .action_key
                .strip_prefix("review:")
                .filter(|profile_id| !profile_id.is_empty())
                .ok_or(TaskBoardLocalAttemptResultValidationError::ArtifactMismatch)?;
            TaskBoardAttemptResultArtifactExpectation::Review {
                profile_id,
                head_revision: head,
            }
        }
        Some(TaskBoardExecutionPhase::Evaluate) => {
            let write = execution.snapshot.workflow_kind.is_write();
            TaskBoardAttemptResultArtifactExpectation::Evaluation {
                exact_head_revision: head,
                head_revision: write.then_some(head),
                revision_cycle: write.then_some(cycle),
            }
        }
        _ => return Err(TaskBoardLocalAttemptResultValidationError::ArtifactMismatch),
    };
    Ok(TaskBoardLocalAttemptResultExpectation {
        execution_id: &attempt.execution_id,
        action_key: &attempt.action_key,
        attempt: attempt.attempt,
        idempotency_key: &attempt.idempotency_key,
        artifact,
    })
}

/// Validate a local attempt result against its execution's expectation.
///
/// # Errors
/// Returns [`TaskBoardLocalAttemptResultValidationError::IdentityMismatch`] if
/// the result's identity fields disagree with `expected`, or
/// [`TaskBoardLocalAttemptResultValidationError::ArtifactMismatch`] if its
/// artifact does not match the expected shape.
pub fn validate_task_board_local_attempt_result(
    result: &TaskBoardLocalAttemptResult,
    expected: &TaskBoardLocalAttemptResultExpectation<'_>,
) -> Result<(), TaskBoardLocalAttemptResultValidationError> {
    if result.schema_version != TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION
        || result.execution_id != expected.execution_id
        || result.action_key != expected.action_key
        || result.attempt != expected.attempt
        || result.idempotency_key != expected.idempotency_key
    {
        return Err(TaskBoardLocalAttemptResultValidationError::IdentityMismatch);
    }
    if artifact_matches(result, expected.artifact) {
        Ok(())
    } else {
        Err(TaskBoardLocalAttemptResultValidationError::ArtifactMismatch)
    }
}

fn artifact_matches(
    result: &TaskBoardLocalAttemptResult,
    expected: TaskBoardAttemptResultArtifactExpectation<'_>,
) -> bool {
    match (expected, &result.artifact) {
        (
            TaskBoardAttemptResultArtifactExpectation::Implementation {
                revision_cycle,
                base_head_revision,
            },
            TaskBoardAttemptResultArtifact::Implementation(artifact),
        ) => {
            result.action_key == format!("implementation:{revision_cycle}")
                && artifact.revision_cycle == revision_cycle
                && artifact.base_head_revision == base_head_revision
                && result.exact_head_revision == artifact.head_revision
                && artifact.head_revision != artifact.base_head_revision
                && !artifact.summary.is_empty()
                && artifact.summary.trim() == artifact.summary
        }
        (
            TaskBoardAttemptResultArtifactExpectation::Review {
                profile_id,
                head_revision,
            },
            TaskBoardAttemptResultArtifact::Review(artifact),
        ) => {
            result.action_key == format!("review:{profile_id}")
                && artifact.profile_id == profile_id
                && result.exact_head_revision == head_revision
                && artifact.result.head_revision == head_revision
        }
        (
            TaskBoardAttemptResultArtifactExpectation::Evaluation {
                exact_head_revision,
                head_revision,
                revision_cycle,
            },
            TaskBoardAttemptResultArtifact::Evaluation(artifact),
        ) => {
            result.action_key == evaluation_action(revision_cycle)
                && result.exact_head_revision == exact_head_revision
                && artifact.head_revision.as_deref() == head_revision
                && artifact.revision_cycle == revision_cycle
        }
        _ => false,
    }
}

fn evaluation_action(revision_cycle: Option<u32>) -> String {
    revision_cycle.map_or_else(|| "evaluate".into(), |cycle| format!("evaluate:{cycle}"))
}
