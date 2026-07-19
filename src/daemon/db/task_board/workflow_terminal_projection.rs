use super::super::workflow_dispatch::workflow_owner;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardExecutionState, TaskBoardItem, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, TaskBoardWorkflowStatus,
};

pub(super) struct TerminalTarget {
    pub(super) item_status: crate::task_board::TaskBoardStatus,
    pub(super) workflow_status: TaskBoardWorkflowStatus,
    pub(super) last_error: Option<String>,
    pub(super) pr_number: Option<u64>,
    pub(super) pr_url: Option<String>,
}

pub(super) fn validate_terminal_execution(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<String, CliError> {
    if execution.snapshot.workflow_kind == TaskBoardWorkflowKind::Unknown {
        return Err(db_error("terminal projection requires a known workflow"));
    }
    terminal_target(execution)?;
    let expected_owner = workflow_owner(&execution.execution_id);
    if execution
        .ownership
        .resources
        .get("admission_owner")
        .map(String::as_str)
        != Some(expected_owner.as_str())
    {
        return Err(db_error(
            "workflow terminal projection has no matching admission owner",
        ));
    }
    Ok(expected_owner)
}

pub(super) fn item_identity_matches(
    item: &TaskBoardItem,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    !item.is_deleted()
        && item.workflow_kind == execution.snapshot.workflow_kind
        && item.workflow.execution_id.as_deref() == Some(execution.execution_id.as_str())
}

pub(super) fn terminal_target(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TerminalTarget, CliError> {
    use crate::task_board::TaskBoardStatus;
    let summary = execution
        .artifacts
        .terminal_outcome
        .as_ref()
        .map(|outcome| outcome.summary.clone())
        .or_else(|| execution.blocked_reason.clone());
    let (pr_number, pr_url) = publication_identity(execution);
    match execution.transition.execution_state {
        TaskBoardExecutionState::Completed => Ok(TerminalTarget {
            item_status: TaskBoardStatus::Done,
            workflow_status: TaskBoardWorkflowStatus::Completed,
            last_error: None,
            pr_number,
            pr_url,
        }),
        TaskBoardExecutionState::HumanRequired => Ok(TerminalTarget {
            item_status: TaskBoardStatus::HumanRequired,
            workflow_status: TaskBoardWorkflowStatus::Paused,
            last_error: Some(summary.unwrap_or_else(|| "workflow requires human review".into())),
            pr_number,
            pr_url,
        }),
        TaskBoardExecutionState::Failed => Ok(TerminalTarget {
            item_status: TaskBoardStatus::Failed,
            workflow_status: TaskBoardWorkflowStatus::Failed,
            last_error: Some(summary.unwrap_or_else(|| "workflow failed".into())),
            pr_number,
            pr_url,
        }),
        TaskBoardExecutionState::Cancelled => Ok(TerminalTarget {
            item_status: TaskBoardStatus::Failed,
            workflow_status: TaskBoardWorkflowStatus::Cancelled,
            last_error: Some(summary.unwrap_or_else(|| "workflow was cancelled".into())),
            pr_number,
            pr_url,
        }),
        _ => Err(db_error(
            "workflow execution is not ready for terminal projection",
        )),
    }
}

pub(super) fn apply_terminal_target(item: &mut TaskBoardItem, target: &TerminalTarget) -> bool {
    if item_matches_target(item, target) {
        return false;
    }
    item.status = target.item_status;
    item.workflow.status = target.workflow_status;
    item.workflow.current_step_id = None;
    item.workflow.last_error.clone_from(&target.last_error);
    if target.pr_number.is_some() {
        item.workflow.pr_number = target.pr_number;
        item.workflow.pr_url.clone_from(&target.pr_url);
    }
    true
}

fn item_matches_target(item: &TaskBoardItem, target: &TerminalTarget) -> bool {
    item.status == target.item_status
        && item.workflow.status == target.workflow_status
        && item.workflow.current_step_id.is_none()
        && item.workflow.last_error == target.last_error
        && target
            .pr_number
            .is_none_or(|number| item.workflow.pr_number == Some(number))
        && target
            .pr_url
            .as_ref()
            .is_none_or(|url| item.workflow.pr_url.as_ref() == Some(url))
}

fn publication_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> (Option<u64>, Option<String>) {
    let Some(pull_request) = execution.transition.pull_request.as_ref() else {
        return execution
            .artifacts
            .provisional_publication
            .as_ref()
            .and_then(|outcome| outcome.external_url.as_deref())
            .and_then(publication_url_identity)
            .unwrap_or((None, None));
    };
    let canonical = format!(
        "https://github.com/{}/pull/{}",
        pull_request.repository, pull_request.number
    );
    let external = execution.attempts.iter().find_map(|attempt| {
        if attempt.action_key != "publish" {
            return None;
        }
        match attempt.artifact.as_ref() {
            Some(crate::task_board::TaskBoardAttemptResultArtifact::Lifecycle(outcome)) => {
                outcome.external_url.clone()
            }
            _ => None,
        }
    });
    (
        Some(pull_request.number),
        Some(external.unwrap_or(canonical)),
    )
}

fn publication_url_identity(url: &str) -> Option<(Option<u64>, Option<String>)> {
    let (_, number) = url.rsplit_once("/pull/")?;
    let number = number.parse::<u64>().ok().filter(|number| *number > 0)?;
    Some((Some(number), Some(url.to_owned())))
}
