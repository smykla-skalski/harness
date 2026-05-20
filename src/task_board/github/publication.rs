use std::fmt::Display;
use std::path::Path;

use axum::http::StatusCode;
use octocrab::models;
use octocrab::params::repos::Reference;
use octocrab::{Error as OctocrabError, Octocrab};
use tokio::task::spawn_blocking;

use crate::daemon::service::git_runtime_profile_for_repository;
use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::sandbox;

use super::GitHubProjectConfig;
pub(crate) use signing::{SigningVerifyOutcome, verify_signing_for_profile};
use signing::{commit_author, local_commit_signature};
use types::{BranchPublicationMode, LocalBranchSnapshot};

mod git_ssh_publish;
mod signing;
mod ssh_signing;
mod types;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitHubBranchState {
    pub commit_sha: String,
    pub tree_sha: String,
}

pub(crate) async fn branch_state_async(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<Option<GitHubBranchState>, CliError> {
    let reference = Reference::Branch(branch.to_string());
    let git_ref = match client
        .repos(config.owner.as_str(), config.repo.as_str())
        .get_ref(&reference)
        .await
    {
        Ok(git_ref) => git_ref,
        Err(error) if github_not_found(&error) => return Ok(None),
        Err(error) => return Err(operation_error(error)),
    };
    let (models::repos::Object::Commit {
        sha: commit_sha, ..
    }
    | models::repos::Object::Tag {
        sha: commit_sha, ..
    }) = git_ref.object
    else {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board github branch '{branch}' does not point to a commit or tag"
        ))
        .into());
    };
    let route = format!(
        "/repos/{owner}/{repo}/git/commits/{commit_sha}",
        owner = config.owner,
        repo = config.repo,
    );
    let commit: models::commits::GitCommitObject = client
        .get(route, None::<&()>)
        .await
        .map_err(operation_error)?;
    Ok(Some(GitHubBranchState {
        commit_sha,
        tree_sha: commit.tree.sha,
    }))
}

pub(crate) async fn publish_branch_from_worktree_async(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    worktree: &Path,
    branch: &str,
    github_token: &str,
) -> Result<(), CliError> {
    let snapshot = load_local_branch_snapshot(worktree, config.repository_slug()).await?;
    let Some(mode) = publication_mode(client, config, branch, &snapshot).await? else {
        return Ok(());
    };
    git_ssh_publish::publish_native_branch(config, worktree, branch, github_token, &snapshot, &mode)
        .await
}

async fn load_local_branch_snapshot(
    worktree: &Path,
    repository_slug: String,
) -> Result<LocalBranchSnapshot, CliError> {
    let worktree = worktree.to_path_buf();
    spawn_blocking(move || local_branch_snapshot(&worktree, repository_slug.as_str()))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "task-board github branch snapshot worker failed: {error}"
            ))
            .into())
        })
}

fn local_branch_snapshot(
    worktree: &Path,
    repository_slug: &str,
) -> Result<LocalBranchSnapshot, CliError> {
    let worktree_scope = sandbox::resolve_project_input(worktree.to_string_lossy().as_ref())?;
    let repository = GitRepository::discover(worktree_scope.path())
        .map_err(|error| snapshot_error("discover repository", error))?;
    let repo = repository
        .open_gix()
        .map_err(|error| snapshot_error("open repository", error))?;
    let head = repo
        .head_commit()
        .map_err(|error| snapshot_error("read HEAD commit", error))?;
    let profile = git_runtime_profile_for_repository(Some(repository_slug))?;
    let commit_signature = local_commit_signature(&head)?;
    Ok(LocalBranchSnapshot {
        head_tree_sha: head
            .tree_id()
            .map_err(|error| snapshot_error("read HEAD tree id", error))?
            .detach()
            .to_hex()
            .to_string(),
        commit_message: String::from_utf8_lossy(
            head.message_raw()
                .map_err(|error| snapshot_error("read HEAD message", error))?
                .as_ref(),
        )
        .into_owned(),
        author: commit_author(
            head.author()
                .map_err(|error| snapshot_error("read HEAD author", error))?,
            profile.author_name.as_deref(),
            profile.author_email.as_deref(),
        )?,
        committer: commit_author(
            head.committer()
                .map_err(|error| snapshot_error("read HEAD committer", error))?,
            profile.author_name.as_deref(),
            profile.author_email.as_deref(),
        )?,
        profile,
        existing_signature: commit_signature,
    })
}

fn github_not_found(error: &OctocrabError) -> bool {
    matches!(
        error,
        OctocrabError::GitHub { source, .. } if source.status_code == StatusCode::NOT_FOUND
    )
}

fn snapshot_error(context: &str, error: impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("task-board github {context}: {error}")).into()
}

fn operation_error(error: OctocrabError) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board github automation failed: {error}"
    )))
    .with_source(error)
}

async fn publication_mode(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    branch: &str,
    snapshot: &LocalBranchSnapshot,
) -> Result<Option<BranchPublicationMode>, CliError> {
    let branch_state = branch_state_async(client, config, branch).await?;
    if branch_state
        .as_ref()
        .is_some_and(|state| state.tree_sha == snapshot.head_tree_sha)
    {
        return Ok(None);
    }
    if let Some(branch_state) = branch_state {
        return Ok(Some(BranchPublicationMode::Update {
            parent_sha: branch_state.commit_sha,
        }));
    }
    let default_state = branch_state_async(client, config, config.default_branch.as_str())
        .await?
        .ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "task-board github default branch '{}' missing on remote",
                config.default_branch
            )))
        })?;
    if default_state.tree_sha == snapshot.head_tree_sha {
        return Ok(None);
    }
    Ok(Some(BranchPublicationMode::Create {
        parent_sha: default_state.commit_sha,
    }))
}
