use std::path::{Path, PathBuf};

use gix::ObjectId;
use tokio::task::spawn_blocking;

use crate::errors::CliError;
use crate::git::GitRepository;
use crate::task_board::{
    TaskBoardImplementationResult, TaskBoardWorkflowExecutionRecord,
    validate_task_board_read_only_run_context,
};

use super::invalid_transition;

pub(super) async fn resolve_local_workflow_head(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<String, CliError> {
    let worktree = workflow_worktree(execution)?;
    spawn_blocking(move || local_head(&worktree))
        .await
        .map_err(|error| invalid_transition(format!("join local head resolver: {error}")))?
}

pub(super) async fn implementation_result_descends_from_base(
    execution: &TaskBoardWorkflowExecutionRecord,
    result: &TaskBoardImplementationResult,
) -> Result<bool, CliError> {
    let worktree = workflow_worktree(execution)?;
    let result = result.clone();
    spawn_blocking(move || local_result_descends_from_base(&worktree, &result))
        .await
        .map_err(|error| invalid_transition(format!("join ancestry resolver: {error}")))?
}

fn workflow_worktree(execution: &TaskBoardWorkflowExecutionRecord) -> Result<PathBuf, CliError> {
    if execution.transition.workflow_kind != execution.snapshot.workflow_kind {
        return Err(invalid_transition(
            "local workflow execution identities do not agree",
        ));
    }
    let context = execution
        .snapshot
        .read_only_run_context
        .as_ref()
        .ok_or_else(|| invalid_transition("local workflow has no immutable run context"))?;
    validate_task_board_read_only_run_context(context)
        .map_err(|error| invalid_transition(error.to_string()))?;
    Ok(PathBuf::from(&context.worktree))
}

pub(super) fn local_head(worktree: &Path) -> Result<String, CliError> {
    let repository = open_repository(worktree)?;
    repository
        .head_commit()
        .map(|commit| commit.id.to_hex().to_string())
        .map_err(|error| invalid_transition(format!("resolve review HEAD: {error}")))
}

fn local_result_descends_from_base(
    worktree: &Path,
    result: &TaskBoardImplementationResult,
) -> Result<bool, CliError> {
    let repository = open_repository(worktree)?;
    let head = object_id(&result.head_revision, "implementation head")?;
    let base = object_id(&result.base_head_revision, "implementation base")?;
    if repository
        .head_commit()
        .map_err(|error| invalid_transition(format!("resolve implementation HEAD: {error}")))?
        .id
        != head
    {
        return Ok(false);
    }
    if repository.find_object(head).is_err() || repository.find_object(base).is_err() {
        return Ok(false);
    }
    Ok(repository
        .merge_base(head, base)
        .is_ok_and(|merge_base| merge_base.detach() == base))
}

fn open_repository(worktree: &Path) -> Result<gix::Repository, CliError> {
    GitRepository::discover(worktree)
        .map_err(|error| invalid_transition(format!("discover review repository: {error}")))?
        .open_gix()
        .map_err(|error| invalid_transition(format!("open review repository: {error}")))
}

fn object_id(value: &str, label: &str) -> Result<ObjectId, CliError> {
    ObjectId::from_hex(value.as_bytes())
        .map_err(|error| invalid_transition(format!("parse {label} '{value}': {error}")))
}

#[cfg(test)]
#[path = "git_evidence_tests.rs"]
mod tests;
