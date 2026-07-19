use std::fmt::Display;
use std::iter;
use std::path::Path;

use gix::{Id, ObjectId, Repository as GixRepository};
use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::sandbox;
use crate::task_board::github::{GitHubAutomationClient, GitHubBranchState, GitHubProjectConfig};

pub(in crate::daemon::service::task_board_github) struct BranchPublication {
    pub needs_push: bool,
    pub waiting_for_commits: bool,
}

pub(in crate::daemon::service::task_board_github) async fn branch_publication_async(
    client: &dyn GitHubAutomationClient,
    worktree: String,
    config: GitHubProjectConfig,
    branch: String,
    expected_parent: Option<&str>,
) -> Result<BranchPublication, CliError> {
    let remote_branch = client.get_branch_state(&config, branch.as_str()).await?;
    let remote_default_branch = if remote_branch.is_none() {
        client
            .get_branch_state(&config, config.default_branch.as_str())
            .await?
    } else {
        None
    };
    if let Some(expected_parent) = expected_parent {
        let observed_parent = remote_branch
            .as_ref()
            .or(remote_default_branch.as_ref())
            .map(|state| state.commit_sha.as_str());
        if observed_parent != Some(expected_parent) {
            let observed_parent = observed_parent.unwrap_or("<missing>");
            return Err(CliErrorKind::invalid_transition(format!(
                "task-board GitHub publication parent changed after preflight: expected \
                 '{expected_parent}', observed '{observed_parent}'"
            ))
            .into());
        }
    }
    spawn_blocking(move || {
        branch_publication(
            &worktree,
            &config,
            remote_branch.as_ref(),
            remote_default_branch.as_ref(),
        )
    })
    .await
    .unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!(
            "task-board github branch publication worker failed: {error}"
        ))
        .into())
    })
}

pub(in crate::daemon::service::task_board_github) async fn push_branch_async(
    client: &dyn GitHubAutomationClient,
    config: &GitHubProjectConfig,
    worktree: String,
    branch: String,
    expected_parent: Option<&str>,
) -> Result<(), CliError> {
    client
        .publish_branch_from_worktree_at_parent(
            config,
            Path::new(worktree.as_str()),
            branch.as_str(),
            expected_parent,
        )
        .await
}

fn branch_publication(
    worktree: &str,
    config: &GitHubProjectConfig,
    remote_branch: Option<&GitHubBranchState>,
    remote_default_branch: Option<&GitHubBranchState>,
) -> Result<BranchPublication, CliError> {
    let worktree_scope = sandbox::resolve_project_input(worktree)?;
    let repository = GitRepository::discover(worktree_scope.path())
        .map_err(|error| CliErrorKind::workflow_io(error.to_string()))?;
    let repo = repository
        .open_gix()
        .map_err(|error| CliErrorKind::workflow_io(error.to_string()))?;
    let head = repo
        .head_commit()
        .map_err(|error| git_operation_error("read HEAD commit for branch publication", error))?;
    let head_id = head.id;
    let head_tree_sha = head
        .tree_id()
        .map_err(|error| git_operation_error("read HEAD tree for branch publication", error))?
        .detach()
        .to_hex()
        .to_string();
    let local_has_new_commits = local_has_new_commits(
        &repository,
        &repo,
        head_id,
        head_tree_sha.as_str(),
        config.default_branch.as_str(),
        remote_default_branch,
    )?;
    Ok(BranchPublication {
        needs_push: local_has_new_commits
            && remote_branch
                .as_ref()
                .is_none_or(|state| state.tree_sha != head_tree_sha),
        waiting_for_commits: remote_branch.is_none() && !local_has_new_commits,
    })
}

fn local_has_new_commits(
    repository: &GitRepository,
    repo: &GixRepository,
    head_id: ObjectId,
    head_tree_sha: &str,
    default_branch: &str,
    remote_default_branch: Option<&GitHubBranchState>,
) -> Result<bool, CliError> {
    if let Some(default_id) = default_branch_id(repository, repo, default_branch) {
        if head_id == default_id {
            return Ok(false);
        }
        let merge_base = repo
            .merge_base(head_id, default_id)
            .map_err(|error| git_operation_error("compute default-branch merge base", error))?;
        return Ok(merge_base.detach() != head_id);
    }
    Ok(remote_default_branch.is_none_or(|state| state.tree_sha != head_tree_sha))
}

fn default_branch_id(
    repository: &GitRepository,
    repo: &GixRepository,
    default_branch: &str,
) -> Option<ObjectId> {
    let remote_name = repository
        .current_branch_remote_name()
        .ok()
        .flatten()
        .or_else(|| {
            repository
                .remote_names()
                .ok()
                .and_then(|remotes| remotes.into_iter().find(|remote| remote == "origin"))
        })
        .or_else(|| {
            repository
                .remote_names()
                .ok()
                .and_then(|mut remotes| remotes.pop())
        });
    let mut candidates = remote_name
        .into_iter()
        .map(|remote| format!("refs/remotes/{remote}/{default_branch}"))
        .chain(iter::once(format!("refs/heads/{default_branch}")));
    candidates.find_map(|reference| {
        repo.rev_parse_single(reference.as_bytes())
            .ok()
            .map(Id::detach)
    })
}

fn git_operation_error(context: &str, error: impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("task-board github {context}: {error}")).into()
}
