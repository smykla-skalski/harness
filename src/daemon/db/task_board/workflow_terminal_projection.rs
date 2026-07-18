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
}

pub(super) fn validate_terminal_execution(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<String, CliError> {
    if !matches!(
        execution.snapshot.workflow_kind,
        TaskBoardWorkflowKind::Review | TaskBoardWorkflowKind::PrReview
    ) {
        return Err(db_error(
            "terminal projection requires a read-only workflow",
        ));
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
            "read-only workflow terminal projection has no matching admission owner",
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
    match execution.transition.execution_state {
        TaskBoardExecutionState::Completed => Ok(TerminalTarget {
            item_status: TaskBoardStatus::Done,
            workflow_status: TaskBoardWorkflowStatus::Completed,
            last_error: None,
        }),
        TaskBoardExecutionState::HumanRequired => Ok(TerminalTarget {
            item_status: TaskBoardStatus::HumanRequired,
            workflow_status: TaskBoardWorkflowStatus::Paused,
            last_error: Some(summary.unwrap_or_else(|| "workflow requires human review".into())),
        }),
        TaskBoardExecutionState::Failed => Ok(TerminalTarget {
            item_status: TaskBoardStatus::Failed,
            workflow_status: TaskBoardWorkflowStatus::Failed,
            last_error: Some(summary.unwrap_or_else(|| "workflow failed".into())),
        }),
        TaskBoardExecutionState::Cancelled => Ok(TerminalTarget {
            item_status: TaskBoardStatus::Failed,
            workflow_status: TaskBoardWorkflowStatus::Cancelled,
            last_error: Some(summary.unwrap_or_else(|| "workflow was cancelled".into())),
        }),
        _ => Err(db_error(
            "read-only workflow execution is not ready for terminal projection",
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
    true
}

fn item_matches_target(item: &TaskBoardItem, target: &TerminalTarget) -> bool {
    item.status == target.item_status
        && item.workflow.status == target.workflow_status
        && item.workflow.current_step_id.is_none()
        && item.workflow.last_error == target.last_error
}
