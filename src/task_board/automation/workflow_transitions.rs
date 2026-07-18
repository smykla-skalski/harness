use serde::{Deserialize, Serialize};

use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardWorkflowKind,
    normalize_repository_slug,
};

const PR_REVIEW_PHASES: [TaskBoardExecutionPhase; 4] = [
    TaskBoardExecutionPhase::Review,
    TaskBoardExecutionPhase::Publish,
    TaskBoardExecutionPhase::Cleanup,
    TaskBoardExecutionPhase::Terminal,
];
const WRITE_PHASES: [TaskBoardExecutionPhase; 8] = [
    TaskBoardExecutionPhase::Planning,
    TaskBoardExecutionPhase::AwaitingApproval,
    TaskBoardExecutionPhase::Implementation,
    TaskBoardExecutionPhase::Review,
    TaskBoardExecutionPhase::Evaluate,
    TaskBoardExecutionPhase::Publish,
    TaskBoardExecutionPhase::Cleanup,
    TaskBoardExecutionPhase::Terminal,
];
const REVIEW_PHASES: [TaskBoardExecutionPhase; 4] = [
    TaskBoardExecutionPhase::Review,
    TaskBoardExecutionPhase::Evaluate,
    TaskBoardExecutionPhase::Cleanup,
    TaskBoardExecutionPhase::Terminal,
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPullRequestIdentity {
    pub repository: String,
    pub number: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardWorkflowTransitionState {
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<TaskBoardExecutionPhase>,
    pub execution_state: TaskBoardExecutionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<TaskBoardPullRequestIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exact_head_revision: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardWorkflowTransitionError {
    #[error("workflow requires an existing pull request identity")]
    MissingPullRequestIdentity,
    #[error("pull request repository '{repository}' is invalid, expected owner/repo")]
    InvalidPullRequestRepository { repository: String },
    #[error("pull request number must be greater than zero")]
    InvalidPullRequestNumber,
    #[error("workflow phase requires an exact head revision")]
    MissingHeadRevision,
    #[error("pull request identity changed during the workflow")]
    PullRequestIdentityChanged,
    #[error("exact head revision changed during a read-only workflow phase")]
    HeadRevisionChanged,
    #[error("workflow kind admits no execution phase")]
    NoAdmittedPhase,
    #[error("workflow is already terminal")]
    AlreadyTerminal,
    #[error("workflow does not support an implementation revision cycle")]
    RevisionCycleUnsupported,
    #[error("phase '{phase:?}' does not belong to workflow '{workflow_kind:?}'")]
    InvalidPhase {
        workflow_kind: TaskBoardWorkflowKind,
        phase: TaskBoardExecutionPhase,
    },
}

#[must_use]
pub const fn task_board_workflow_phases(
    workflow_kind: TaskBoardWorkflowKind,
) -> &'static [TaskBoardExecutionPhase] {
    match workflow_kind {
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix => &WRITE_PHASES,
        TaskBoardWorkflowKind::PrReview => &PR_REVIEW_PHASES,
        TaskBoardWorkflowKind::Review => &REVIEW_PHASES,
        TaskBoardWorkflowKind::Unknown => &[],
    }
}

/// Validate that a workflow transition state satisfies its workflow and phase invariants.
///
/// # Errors
///
/// Returns an error when the phase is not admitted or required pull request or head data is
/// missing or invalid.
pub fn validate_task_board_workflow_transition_state(
    state: &TaskBoardWorkflowTransitionState,
) -> Result<(), TaskBoardWorkflowTransitionError> {
    let Some(phase) = state.phase else {
        return if state.workflow_kind == TaskBoardWorkflowKind::Unknown {
            Ok(())
        } else {
            Err(TaskBoardWorkflowTransitionError::NoAdmittedPhase)
        };
    };
    if !task_board_workflow_phases(state.workflow_kind).contains(&phase) {
        return Err(TaskBoardWorkflowTransitionError::InvalidPhase {
            workflow_kind: state.workflow_kind,
            phase,
        });
    }
    validate_state_invariants(state, phase)
}

/// Construct the initial transition state for a workflow.
///
/// # Errors
///
/// Returns an error when required pull request or head data is missing or invalid.
pub fn start_task_board_workflow(
    workflow_kind: TaskBoardWorkflowKind,
    pull_request: Option<&TaskBoardPullRequestIdentity>,
    exact_head_revision: Option<&str>,
) -> Result<TaskBoardWorkflowTransitionState, TaskBoardWorkflowTransitionError> {
    let Some(&phase) = task_board_workflow_phases(workflow_kind).first() else {
        return Ok(TaskBoardWorkflowTransitionState {
            workflow_kind,
            phase: None,
            execution_state: TaskBoardExecutionState::HumanRequired,
            pull_request: None,
            exact_head_revision: None,
        });
    };
    let pull_request = normalize_pull_request(pull_request)?;
    let exact_head_revision = normalize_head(exact_head_revision)?;
    if matches!(
        workflow_kind,
        TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
    ) && pull_request.is_none()
    {
        return Err(TaskBoardWorkflowTransitionError::MissingPullRequestIdentity);
    }
    if matches!(
        workflow_kind,
        TaskBoardWorkflowKind::PrFix
            | TaskBoardWorkflowKind::PrReview
            | TaskBoardWorkflowKind::Review
    ) && exact_head_revision.is_none()
    {
        return Err(TaskBoardWorkflowTransitionError::MissingHeadRevision);
    }
    Ok(TaskBoardWorkflowTransitionState {
        workflow_kind,
        phase: Some(phase),
        execution_state: state_for_phase(phase),
        pull_request,
        exact_head_revision,
    })
}

/// Restart a write workflow at implementation after review or evaluation requested changes.
///
/// # Errors
///
/// Returns an error unless the workflow is a supported write kind in Review or Evaluate.
pub fn restart_task_board_workflow_revision(
    state: &TaskBoardWorkflowTransitionState,
) -> Result<TaskBoardWorkflowTransitionState, TaskBoardWorkflowTransitionError> {
    if !matches!(
        state.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) || !matches!(
        state.phase,
        Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate)
    ) {
        return Err(TaskBoardWorkflowTransitionError::RevisionCycleUnsupported);
    }
    validate_state_invariants(
        state,
        state
            .phase
            .ok_or(TaskBoardWorkflowTransitionError::RevisionCycleUnsupported)?,
    )?;
    Ok(TaskBoardWorkflowTransitionState {
        workflow_kind: state.workflow_kind,
        phase: Some(TaskBoardExecutionPhase::Implementation),
        execution_state: TaskBoardExecutionState::Pending,
        pull_request: state.pull_request.clone(),
        exact_head_revision: state.exact_head_revision.clone(),
    })
}

/// Advance a workflow transition state to its next admitted phase.
///
/// # Errors
///
/// Returns an error when the current state is invalid or terminal, observed identity data changes,
/// or the next phase cannot be admitted.
pub fn advance_task_board_workflow(
    state: &TaskBoardWorkflowTransitionState,
    observed_pull_request: Option<&TaskBoardPullRequestIdentity>,
    observed_head_revision: Option<&str>,
) -> Result<TaskBoardWorkflowTransitionState, TaskBoardWorkflowTransitionError> {
    let phase = state
        .phase
        .ok_or(TaskBoardWorkflowTransitionError::NoAdmittedPhase)?;
    if phase == TaskBoardExecutionPhase::Terminal {
        return Err(TaskBoardWorkflowTransitionError::AlreadyTerminal);
    }
    validate_state_invariants(state, phase)?;
    let phases = task_board_workflow_phases(state.workflow_kind);
    let index = phases
        .iter()
        .position(|candidate| *candidate == phase)
        .ok_or(TaskBoardWorkflowTransitionError::InvalidPhase {
            workflow_kind: state.workflow_kind,
            phase,
        })?;
    let next_phase =
        *phases
            .get(index + 1)
            .ok_or(TaskBoardWorkflowTransitionError::InvalidPhase {
                workflow_kind: state.workflow_kind,
                phase,
            })?;
    let pull_request = transitioned_pull_request(state, observed_pull_request)?;
    let exact_head_revision = transitioned_head(state, phase, observed_head_revision)?;
    if next_phase == TaskBoardExecutionPhase::Review && exact_head_revision.is_none() {
        return Err(TaskBoardWorkflowTransitionError::MissingHeadRevision);
    }
    Ok(TaskBoardWorkflowTransitionState {
        workflow_kind: state.workflow_kind,
        phase: Some(next_phase),
        execution_state: state_for_phase(next_phase),
        pull_request,
        exact_head_revision,
    })
}

fn transitioned_pull_request(
    state: &TaskBoardWorkflowTransitionState,
    observed: Option<&TaskBoardPullRequestIdentity>,
) -> Result<Option<TaskBoardPullRequestIdentity>, TaskBoardWorkflowTransitionError> {
    let expected = normalize_pull_request(state.pull_request.as_ref())?;
    let observed = normalize_pull_request(observed)?;
    if let (Some(expected), Some(actual)) = (&expected, &observed)
        && expected != actual
        && matches!(
            state.workflow_kind,
            TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
        )
    {
        return Err(TaskBoardWorkflowTransitionError::PullRequestIdentityChanged);
    }
    Ok(expected.or(observed))
}

fn transitioned_head(
    state: &TaskBoardWorkflowTransitionState,
    phase: TaskBoardExecutionPhase,
    observed: Option<&str>,
) -> Result<Option<String>, TaskBoardWorkflowTransitionError> {
    let expected = normalize_head(state.exact_head_revision.as_deref())?;
    let observed = normalize_head(observed)?;
    if exact_head_is_frozen(state.workflow_kind, phase) {
        if let (Some(expected), Some(actual)) = (&expected, &observed)
            && expected != actual
        {
            return Err(TaskBoardWorkflowTransitionError::HeadRevisionChanged);
        }
        return Ok(expected.or(observed));
    }
    Ok(observed.or(expected))
}

fn validate_state_invariants(
    state: &TaskBoardWorkflowTransitionState,
    phase: TaskBoardExecutionPhase,
) -> Result<(), TaskBoardWorkflowTransitionError> {
    let pull_request = normalize_pull_request(state.pull_request.as_ref())?;
    if matches!(
        state.workflow_kind,
        TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
    ) && pull_request.is_none()
    {
        return Err(TaskBoardWorkflowTransitionError::MissingPullRequestIdentity);
    }
    let head = normalize_head(state.exact_head_revision.as_deref())?;
    if (state.workflow_kind == TaskBoardWorkflowKind::PrFix
        || exact_head_is_frozen(state.workflow_kind, phase))
        && head.is_none()
    {
        return Err(TaskBoardWorkflowTransitionError::MissingHeadRevision);
    }
    Ok(())
}

const fn exact_head_is_frozen(
    workflow_kind: TaskBoardWorkflowKind,
    phase: TaskBoardExecutionPhase,
) -> bool {
    matches!(
        workflow_kind,
        TaskBoardWorkflowKind::PrReview | TaskBoardWorkflowKind::Review
    ) || matches!(
        phase,
        TaskBoardExecutionPhase::Review
            | TaskBoardExecutionPhase::Evaluate
            | TaskBoardExecutionPhase::Publish
            | TaskBoardExecutionPhase::Cleanup
            | TaskBoardExecutionPhase::Terminal
    )
}

fn normalize_pull_request(
    identity: Option<&TaskBoardPullRequestIdentity>,
) -> Result<Option<TaskBoardPullRequestIdentity>, TaskBoardWorkflowTransitionError> {
    let Some(identity) = identity else {
        return Ok(None);
    };
    if identity.number == 0 {
        return Err(TaskBoardWorkflowTransitionError::InvalidPullRequestNumber);
    }
    let repository = normalize_repository_slug(Some(&identity.repository)).ok_or_else(|| {
        TaskBoardWorkflowTransitionError::InvalidPullRequestRepository {
            repository: identity.repository.clone(),
        }
    })?;
    Ok(Some(TaskBoardPullRequestIdentity {
        repository,
        number: identity.number,
    }))
}

fn normalize_head(
    head_revision: Option<&str>,
) -> Result<Option<String>, TaskBoardWorkflowTransitionError> {
    let Some(head_revision) = head_revision else {
        return Ok(None);
    };
    let head_revision = head_revision.trim();
    if head_revision.is_empty() {
        Err(TaskBoardWorkflowTransitionError::MissingHeadRevision)
    } else {
        Ok(Some(head_revision.to_owned()))
    }
}

const fn state_for_phase(phase: TaskBoardExecutionPhase) -> TaskBoardExecutionState {
    match phase {
        TaskBoardExecutionPhase::AwaitingApproval => TaskBoardExecutionState::AwaitingApproval,
        TaskBoardExecutionPhase::Terminal => TaskBoardExecutionState::Completed,
        TaskBoardExecutionPhase::Planning
        | TaskBoardExecutionPhase::Implementation
        | TaskBoardExecutionPhase::Review
        | TaskBoardExecutionPhase::Evaluate
        | TaskBoardExecutionPhase::Publish
        | TaskBoardExecutionPhase::Cleanup => TaskBoardExecutionState::Pending,
    }
}
