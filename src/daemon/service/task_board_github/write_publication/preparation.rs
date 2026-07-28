use std::path::Path;

use crate::task_board::github::{GitHubAutomation, GitHubAutomationToggles};
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowKind, TaskBoardWorkflowState,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::evidence::publication_number;
use super::invalid_transition;

pub(in crate::daemon::service::task_board_github) fn prepare_default_publication_item(
    mut item: TaskBoardItem,
    execution_repository: &str,
    frozen_worktree: &Path,
) -> Result<TaskBoardItem, CliError> {
    let frozen_worktree = frozen_worktree
        .to_str()
        .ok_or_else(|| invalid_transition("write publication worktree is not valid UTF-8"))?;
    item.status = TaskBoardStatus::InReview;
    item.project_id = Some(execution_repository.to_string());
    item.workflow.worktree = Some(frozen_worktree.to_string());
    item.workflow.last_error = None;
    Ok(item)
}

pub(in crate::daemon::service::task_board_github) fn default_publication_result(
    workflow: &TaskBoardWorkflowState,
    frozen_number: Option<u64>,
    mutated: bool,
) -> Result<(u64, bool), CliError> {
    if workflow.pr_number.is_none()
        && let Some(error) = workflow.last_error.as_deref()
    {
        return Err(CliErrorKind::workflow_io(format!(
            "write workflow publication failed: {error}"
        ))
        .into());
    }
    publication_number(workflow.pr_number, frozen_number).map(|number| (number, mutated))
}

/// Takes the toggles rather than a config, because it is called both before a
/// repository is known and after one is stamped on, and those are two types.
pub(in crate::daemon::service::task_board_github) fn validate_publication_automations(
    enabled_automations: &GitHubAutomationToggles,
    workflow_kind: TaskBoardWorkflowKind,
) -> Result<(), CliError> {
    if !enabled_automations.enables(GitHubAutomation::CreateBranch) {
        return Err(invalid_transition(
            "write workflow publication requires CreateBranch automation",
        ));
    }
    if workflow_kind == TaskBoardWorkflowKind::DefaultTask
        && !enabled_automations.enables(GitHubAutomation::OpenPullRequest)
    {
        return Err(invalid_transition(
            "DefaultTask publication requires OpenPullRequest automation",
        ));
    }
    if matches!(
        workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) {
        Ok(())
    } else {
        Err(invalid_transition(
            "write publication requires a DefaultTask or PrFix execution",
        ))
    }
}
