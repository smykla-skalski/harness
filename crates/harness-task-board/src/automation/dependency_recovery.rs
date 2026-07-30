use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};

use super::{
    TaskBoardAttemptState, TaskBoardDependencyCheckResumeRecord, TaskBoardDependencyCheckWait,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardWorkflowExecutionRecord, valid_head_revision,
};
use crate::github::{ActionState, PullRequestActionFailureClass, RecordedAction};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyRecoveryClass {
    Resumable,
    Completed,
    Uncertain,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyRecoveryStep {
    AgentRun,
    CheckWait,
    GitHubAction,
    Advance,
    Stop,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyRecoveryDecision {
    pub class: TaskBoardDependencyRecoveryClass,
    pub step: TaskBoardDependencyRecoveryStep,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exact_head_revision: Option<String>,
    pub detail: String,
}

/// Classify the one dependency workflow step a restarted daemon may safely resume.
///
/// # Errors
/// Returns an invalid-transition error when durable state names multiple current attempts.
pub fn classify_task_board_dependency_workflow_recovery(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardDependencyRecoveryDecision, CliError> {
    if let Some(decision) = terminal_decision(execution) {
        return Ok(decision);
    }
    let active_attempts = execution
        .attempts
        .iter()
        .filter(|attempt| {
            matches!(
                attempt.state,
                TaskBoardAttemptState::Preparing
                    | TaskBoardAttemptState::Starting
                    | TaskBoardAttemptState::Running
            )
        })
        .count();
    if active_attempts > 1 {
        return Err(recovery_error(
            "dependency workflow has multiple active attempts",
        ));
    }
    let mut attempts = execution
        .attempts
        .iter()
        .filter(|attempt| attempt_is_current(execution, attempt))
        .collect::<Vec<_>>();
    attempts.sort_by_key(|attempt| attempt.attempt);
    let attempt = attempts.last().copied();
    Ok(match attempt {
        Some(attempt) => classify_attempt(execution, attempt),
        None => resumable_without_attempt(execution),
    })
}

/// Classify a durable exact-head check wait after a daemon restart.
///
/// # Errors
/// Returns an invalid-transition error when the wait or retained result is malformed or mismatched.
pub fn classify_task_board_dependency_check_recovery(
    wait: &TaskBoardDependencyCheckWait,
    result: Option<&TaskBoardDependencyCheckResumeRecord>,
) -> Result<TaskBoardDependencyRecoveryDecision, CliError> {
    validate_wait(wait)?;
    let Some(result) = result else {
        return Ok(decision(
            TaskBoardDependencyRecoveryClass::Resumable,
            TaskBoardDependencyRecoveryStep::CheckWait,
            Some(wait.resume_id.clone()),
            Some(wait.exact_head_revision.clone()),
            "resume the retained check wait on its original head",
        ));
    };
    if result.resume_id != wait.resume_id
        || result.route_id != wait.route_id
        || result.identity.repository != wait.identity.repository
        || result.identity.number != wait.identity.number
        || result.exact_head_revision != wait.exact_head_revision
    {
        return Err(recovery_error(
            "dependency check recovery result does not match its retained exact-head wait",
        ));
    }
    Ok(decision(
        TaskBoardDependencyRecoveryClass::Completed,
        TaskBoardDependencyRecoveryStep::Advance,
        Some(wait.resume_id.clone()),
        Some(wait.exact_head_revision.clone()),
        "the retained check wait already has one terminal result",
    ))
}

#[must_use]
pub fn classify_task_board_dependency_action_recovery(
    action: &RecordedAction,
) -> TaskBoardDependencyRecoveryDecision {
    let step = TaskBoardDependencyRecoveryStep::GitHubAction;
    let head = Some(action.action.head_revision.clone());
    match action.state {
        ActionState::Pending | ActionState::Uncertain => decision(
            TaskBoardDependencyRecoveryClass::Uncertain,
            step,
            Some(action.action.id.clone()),
            head,
            "reconcile the GitHub action against fresh evidence before retrying",
        ),
        ActionState::Succeeded => decision(
            TaskBoardDependencyRecoveryClass::Completed,
            TaskBoardDependencyRecoveryStep::Advance,
            Some(action.action.id.clone()),
            head,
            "the GitHub action already completed",
        ),
        ActionState::Failed(PullRequestActionFailureClass::Transient) => decision(
            TaskBoardDependencyRecoveryClass::Resumable,
            step,
            Some(action.action.id.clone()),
            head,
            "retry the transient GitHub action through its durable ledger",
        ),
        ActionState::Failed(PullRequestActionFailureClass::Permanent) => decision(
            TaskBoardDependencyRecoveryClass::Failed,
            TaskBoardDependencyRecoveryStep::Stop,
            Some(action.action.id.clone()),
            head,
            "the GitHub action failed permanently",
        ),
    }
}

fn terminal_decision(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Option<TaskBoardDependencyRecoveryDecision> {
    let class = match execution.transition.execution_state {
        TaskBoardExecutionState::Completed => TaskBoardDependencyRecoveryClass::Completed,
        TaskBoardExecutionState::HumanRequired
        | TaskBoardExecutionState::Failed
        | TaskBoardExecutionState::Cancelled => TaskBoardDependencyRecoveryClass::Failed,
        _ => return None,
    };
    Some(decision(
        class,
        TaskBoardDependencyRecoveryStep::Stop,
        None,
        execution.transition.exact_head_revision.clone(),
        "the dependency workflow is already terminal",
    ))
}

fn classify_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> TaskBoardDependencyRecoveryDecision {
    let head = execution.transition.exact_head_revision.clone();
    let key = Some(attempt.action_key.clone());
    match attempt.state {
        TaskBoardAttemptState::Completed => decision(
            TaskBoardDependencyRecoveryClass::Completed,
            TaskBoardDependencyRecoveryStep::Advance,
            key,
            head,
            "the interrupted step completed and its next transition may be applied once",
        ),
        TaskBoardAttemptState::Unknown => decision(
            TaskBoardDependencyRecoveryClass::Uncertain,
            step_for(execution),
            key,
            head,
            "the interrupted step outcome must be reconciled before retrying",
        ),
        TaskBoardAttemptState::Failed
            if attempt.failure_class == Some(TaskBoardFailureClass::Transient) =>
        {
            decision(
                TaskBoardDependencyRecoveryClass::Resumable,
                step_for(execution),
                key,
                head,
                "resume the transient failure through its bounded retry policy",
            )
        }
        TaskBoardAttemptState::Failed | TaskBoardAttemptState::Cancelled => decision(
            TaskBoardDependencyRecoveryClass::Failed,
            TaskBoardDependencyRecoveryStep::Stop,
            key,
            head,
            "the interrupted step ended without a resumable result",
        ),
        TaskBoardAttemptState::Running
            if execution.transition.phase == Some(TaskBoardExecutionPhase::Publish) =>
        {
            decision(
                TaskBoardDependencyRecoveryClass::Uncertain,
                TaskBoardDependencyRecoveryStep::GitHubAction,
                key,
                head,
                "reconcile the claimed GitHub side effect before retrying",
            )
        }
        TaskBoardAttemptState::RetryWait => decision(
            TaskBoardDependencyRecoveryClass::Resumable,
            step_for(execution),
            key,
            head,
            "resume the durable retry delay without starting a duplicate attempt",
        ),
        TaskBoardAttemptState::Preparing
        | TaskBoardAttemptState::Starting
        | TaskBoardAttemptState::Running => decision(
            TaskBoardDependencyRecoveryClass::Resumable,
            step_for(execution),
            key,
            head,
            "reconnect to the deterministic agent run or resume its start",
        ),
    }
}

fn resumable_without_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> TaskBoardDependencyRecoveryDecision {
    decision(
        TaskBoardDependencyRecoveryClass::Resumable,
        step_for(execution),
        None,
        execution.transition.exact_head_revision.clone(),
        "schedule the next eligible dependency workflow step once",
    )
}

fn step_for(execution: &TaskBoardWorkflowExecutionRecord) -> TaskBoardDependencyRecoveryStep {
    match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Publish) => TaskBoardDependencyRecoveryStep::GitHubAction,
        Some(TaskBoardExecutionPhase::Cleanup | TaskBoardExecutionPhase::Terminal) => {
            TaskBoardDependencyRecoveryStep::Advance
        }
        _ => TaskBoardDependencyRecoveryStep::AgentRun,
    }
}

fn attempt_is_current(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> bool {
    match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Implementation) => {
            attempt.action_key
                == format!(
                    "implementation:{}",
                    execution.artifacts.current_revision_cycle
                )
        }
        Some(TaskBoardExecutionPhase::Review) => attempt
            .action_key
            .strip_prefix("review:")
            .is_some_and(|profile_id| {
                !execution.artifacts.review_cycles.iter().any(|cycle| {
                    cycle.revision_cycle == execution.artifacts.current_revision_cycle
                        && cycle
                            .outcomes
                            .iter()
                            .any(|outcome| outcome.profile_id == profile_id)
                })
            }),
        Some(TaskBoardExecutionPhase::Evaluate) => {
            attempt.action_key == "evaluate"
                || attempt.action_key
                    == format!("evaluate:{}", execution.artifacts.current_revision_cycle)
        }
        Some(TaskBoardExecutionPhase::Publish) => attempt.action_key == "publish",
        Some(TaskBoardExecutionPhase::Cleanup) => attempt.action_key == "cleanup",
        _ => false,
    }
}

fn validate_wait(wait: &TaskBoardDependencyCheckWait) -> Result<(), CliError> {
    if wait.resume_id.trim().is_empty()
        || wait.route_id.trim().is_empty()
        || wait.identity.repository.trim().is_empty()
        || wait.identity.number == 0
        || !valid_head_revision(&wait.exact_head_revision)
        || wait.required_checks.is_empty()
        || wait
            .required_checks
            .iter()
            .any(|check| check.trim().is_empty())
    {
        return Err(recovery_error(
            "dependency check recovery wait has incomplete exact-head state",
        ));
    }
    Ok(())
}

fn decision(
    class: TaskBoardDependencyRecoveryClass,
    step: TaskBoardDependencyRecoveryStep,
    action_key: Option<String>,
    exact_head_revision: Option<String>,
    detail: &str,
) -> TaskBoardDependencyRecoveryDecision {
    TaskBoardDependencyRecoveryDecision {
        class,
        step,
        action_key,
        exact_head_revision,
        detail: detail.into(),
    }
}

fn recovery_error(detail: &str) -> CliError {
    CliErrorKind::invalid_transition(detail.to_owned()).into()
}

#[cfg(test)]
mod tests;
