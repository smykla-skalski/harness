use std::fmt::Display;
use std::path::Path;

use serde::Deserialize;
use serde_json::json;
use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use crate::sandbox;
use crate::task_board::TaskBoardGitRuntimeConfig;

use super::{GitHubAutomation, GitHubProjectConfig};
pub(crate) use signing::{SigningVerifyOutcome, verify_signing_for_profile};
use signing::{commit_author, local_commit_signature};
use types::{BranchPublicationMode, LocalBranchSnapshot};

mod git_ssh_publish;
#[cfg(test)]
mod mutation_tests;
mod signing;
mod ssh_signing;
mod types;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitHubBranchState {
    pub commit_sha: String,
    pub tree_sha: String,
}

pub(crate) async fn branch_state_async(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<Option<GitHubBranchState>, CliError> {
    let response: BranchStateResponse = client
        .graphql(
            GitHubRequestDescriptor::graphql(
                "task_board.github.branch_state",
                GitHubPriority::FreshRead,
                GitHubCachePolicy::no_store(),
            ),
            json!({
            "query": BRANCH_STATE_QUERY,
            "variables": {
                "owner": config.owner.as_str(),
                "repo": config.repo.as_str(),
                "qualifiedName": branch,
            },
            }),
        )
        .await
        .map(|response| response.body)?;
    let Some(reference) = response.repository.and_then(|repo| repo.ref_field) else {
        return Ok(None);
    };
    reference.target.into_branch_state(branch).map(Some)
}

pub(crate) async fn publish_branch_from_worktree_async(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    worktree: &Path,
    branch: &str,
    expected_parent: Option<&str>,
    github_token: &str,
    runtime_config: &TaskBoardGitRuntimeConfig,
) -> Result<(), CliError> {
    if !config
        .enabled_automations
        .enables(GitHubAutomation::CreateBranch)
    {
        return Err(CliErrorKind::invalid_transition(
            "task-board GitHub branch publication requires CreateBranch automation",
        )
        .into());
    }
    let snapshot =
        load_local_branch_snapshot(worktree, config.repository_slug(), runtime_config.clone())
            .await?;
    let Some(mode) = publication_mode(client, config, branch, &snapshot, expected_parent).await?
    else {
        return Ok(());
    };
    git_ssh_publish::publish_native_branch(config, worktree, branch, github_token, &snapshot, &mode)
        .await
}

async fn load_local_branch_snapshot(
    worktree: &Path,
    repository_slug: String,
    runtime_config: TaskBoardGitRuntimeConfig,
) -> Result<LocalBranchSnapshot, CliError> {
    let worktree = worktree.to_path_buf();
    spawn_blocking(move || {
        local_branch_snapshot(&worktree, repository_slug.as_str(), &runtime_config)
    })
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
    runtime_config: &TaskBoardGitRuntimeConfig,
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
    let profile = runtime_config.resolved_profile(Some(repository_slug));
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

fn snapshot_error(context: &str, error: impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("task-board github {context}: {error}")).into()
}

async fn publication_mode(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    branch: &str,
    snapshot: &LocalBranchSnapshot,
    expected_parent: Option<&str>,
) -> Result<Option<BranchPublicationMode>, CliError> {
    let branch_state = branch_state_async(client, config, branch).await?;
    if let Some(branch_state) = branch_state {
        validate_publication_parent(expected_parent, &branch_state.commit_sha)?;
        if branch_state.tree_sha == snapshot.head_tree_sha {
            return Ok(None);
        }
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
    validate_publication_parent(expected_parent, &default_state.commit_sha)?;
    if default_state.tree_sha == snapshot.head_tree_sha {
        return Ok(None);
    }
    Ok(Some(BranchPublicationMode::Create {
        parent_sha: default_state.commit_sha,
    }))
}

fn validate_publication_parent(
    expected_parent: Option<&str>,
    observed_parent: &str,
) -> Result<(), CliError> {
    if expected_parent.is_none_or(|expected| expected == observed_parent) {
        return Ok(());
    }
    Err(CliErrorKind::invalid_transition(
        "task-board GitHub publication parent changed after preflight",
    )
    .into())
}

const BRANCH_STATE_QUERY: &str = r"
query($owner: String!, $repo: String!, $qualifiedName: String!) {
  repository(owner: $owner, name: $repo) {
    ref(qualifiedName: $qualifiedName) {
      target {
        __typename
        ... on Commit {
          oid
          tree { oid }
        }
        ... on Tag {
          target {
            __typename
            ... on Commit {
              oid
              tree { oid }
            }
          }
        }
      }
    }
  }
}
";

#[derive(Debug, Deserialize)]
struct BranchStateResponse {
    repository: Option<BranchStateRepository>,
}

#[derive(Debug, Deserialize)]
struct BranchStateRepository {
    #[serde(rename = "ref")]
    ref_field: Option<BranchStateReference>,
}

#[derive(Debug, Deserialize)]
struct BranchStateReference {
    target: BranchStateTarget,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "__typename")]
enum BranchStateTarget {
    Commit {
        oid: String,
        tree: BranchStateTree,
    },
    Tag {
        target: Box<BranchStateTarget>,
    },
    #[serde(other)]
    Unknown,
}

impl BranchStateTarget {
    fn into_branch_state(self, branch: &str) -> Result<GitHubBranchState, CliError> {
        match self {
            Self::Commit { oid, tree } => Ok(GitHubBranchState {
                commit_sha: oid,
                tree_sha: tree.oid,
            }),
            Self::Tag { target } => target.into_branch_state(branch),
            Self::Unknown => Err(CliErrorKind::workflow_io(format!(
                "task-board github branch '{branch}' does not point to a commit or tag"
            ))
            .into()),
        }
    }
}

#[derive(Debug, Deserialize)]
struct BranchStateTree {
    oid: String,
}
