use std::fmt::Display;
use std::path::Path;

use axum::http::StatusCode;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as Base64Standard;
use futures_util::future::BoxFuture;
use gix::{Tree, object::tree::EntryKind};
use octocrab::models;
use octocrab::params::repos::Reference;
use octocrab::{Error as OctocrabError, Octocrab};
use tokio::task::spawn_blocking;

use crate::daemon::service::git_runtime_profile_for_repository;
use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::sandbox;
use crate::task_board::TaskBoardGitSigningMode;

use super::GitHubProjectConfig;
use signing::{
    commit_author, local_commit_signature, native_git_transport_required_error,
    publication_signature, rest_commit_signature_boundary, unsigned_commit_payload,
    validate_rest_publication_signature_support,
};
pub(crate) use signing::{SigningVerifyOutcome, verify_signing_for_profile};
use types::{
    BranchPublicationMode, GitHubCreateBlobRequest, GitHubCreateCommitRequest,
    GitHubCreateTreeRequest, GitHubObjectShaResponse, GitHubTreeEntryRequest,
    GitHubUpdateRefRequest, LocalBranchSnapshot, LocalTreeEntry, LocalTreeSnapshot,
    NativeGitTransportReason, RestCommitSignatureBoundary,
};

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
    if should_publish_configured_ssh_with_git(&snapshot)? {
        return git_ssh_publish::publish_configured_ssh_branch(
            config,
            worktree,
            branch,
            github_token,
            &snapshot,
            &mode,
        )
        .await;
    }
    ensure_rest_publication_supported_or_prepare_native_boundary(&snapshot, &mode)?;
    let root_tree_sha = upload_tree(client, config, &snapshot.root_tree).await?;
    let commit_sha =
        create_commit(client, config, &snapshot, &root_tree_sha, mode.parent_sha()).await?;
    update_branch_ref(client, config, branch, commit_sha.as_str(), &mode).await
}

fn should_publish_configured_ssh_with_git(
    snapshot: &LocalBranchSnapshot,
) -> Result<bool, CliError> {
    match rest_commit_signature_boundary(&snapshot.profile, snapshot.existing_signature.as_ref())? {
        RestCommitSignatureBoundary::NativeGitTransportRequired(
            NativeGitTransportReason::ConfiguredSshSigning,
        ) => Ok(true),
        _ => Ok(false),
    }
}

fn ensure_rest_publication_supported_or_prepare_native_boundary(
    snapshot: &LocalBranchSnapshot,
    mode: &BranchPublicationMode,
) -> Result<(), CliError> {
    match rest_commit_signature_boundary(&snapshot.profile, snapshot.existing_signature.as_ref())? {
        RestCommitSignatureBoundary::RestSupported => validate_rest_publication_signature_support(
            &snapshot.profile,
            snapshot.existing_signature.as_ref(),
        ),
        RestCommitSignatureBoundary::NativeGitTransportRequired(
            NativeGitTransportReason::ConfiguredSshSigning,
        ) => {
            let _native_commit = ssh_signing::native_ssh_commit_object(
                snapshot,
                snapshot.head_tree_sha.as_str(),
                mode.parent_sha(),
            )?;
            Err(native_git_transport_required_error(
                NativeGitTransportReason::ConfiguredSshSigning,
            ))
        }
        RestCommitSignatureBoundary::NativeGitTransportRequired(reason) => {
            Err(native_git_transport_required_error(reason))
        }
    }
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
    let root_tree = head
        .tree()
        .map_err(|error| snapshot_error("read HEAD tree", error))?;
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
        root_tree: collect_tree(&root_tree)?,
    })
}

fn collect_tree(tree: &Tree<'_>) -> Result<LocalTreeSnapshot, CliError> {
    let mut entries = Vec::new();
    for entry in tree.iter() {
        let entry = entry.map_err(|error| snapshot_error("decode tree entry", error))?;
        let path = String::from_utf8_lossy(entry.filename().as_ref()).into_owned();
        let mode = format!("{:06o}", entry.mode());
        match entry.kind() {
            EntryKind::Tree => {
                let subtree = entry
                    .object()
                    .map_err(|error| snapshot_error("load subtree", error))?
                    .into_tree();
                entries.push(LocalTreeEntry::Tree {
                    path,
                    mode,
                    tree: collect_tree(&subtree)?,
                });
            }
            EntryKind::Commit => {
                entries.push(LocalTreeEntry::Commit {
                    path,
                    mode,
                    sha: entry.id().detach().to_hex().to_string(),
                });
            }
            _ => {
                let blob = entry
                    .object()
                    .map_err(|error| snapshot_error("load blob", error))?
                    .into_blob();
                entries.push(LocalTreeEntry::Blob {
                    path,
                    mode,
                    content: blob.data.clone(),
                });
            }
        }
    }
    Ok(LocalTreeSnapshot { entries })
}

fn upload_tree<'a>(
    client: &'a Octocrab,
    config: &'a GitHubProjectConfig,
    tree: &'a LocalTreeSnapshot,
) -> BoxFuture<'a, Result<String, CliError>> {
    Box::pin(async move {
        let mut entries = Vec::with_capacity(tree.entries.len());
        for entry in &tree.entries {
            entries.push(match entry {
                LocalTreeEntry::Blob {
                    path,
                    mode,
                    content,
                } => GitHubTreeEntryRequest {
                    path: path.clone(),
                    mode: mode.clone(),
                    kind: "blob".to_string(),
                    sha: Some(upload_blob(client, config, content).await?),
                },
                LocalTreeEntry::Tree { path, mode, tree } => GitHubTreeEntryRequest {
                    path: path.clone(),
                    mode: mode.clone(),
                    kind: "tree".to_string(),
                    sha: Some(upload_tree(client, config, tree).await?),
                },
                LocalTreeEntry::Commit { path, mode, sha } => GitHubTreeEntryRequest {
                    path: path.clone(),
                    mode: mode.clone(),
                    kind: "commit".to_string(),
                    sha: Some(sha.clone()),
                },
            });
        }
        let route = format!(
            "/repos/{owner}/{repo}/git/trees",
            owner = config.owner,
            repo = config.repo,
        );
        let response: GitHubObjectShaResponse = client
            .post(route, Some(&GitHubCreateTreeRequest { tree: entries }))
            .await
            .map_err(operation_error)?;
        Ok(response.sha)
    })
}

async fn upload_blob(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    content: &[u8],
) -> Result<String, CliError> {
    let route = format!(
        "/repos/{owner}/{repo}/git/blobs",
        owner = config.owner,
        repo = config.repo,
    );
    let response: GitHubObjectShaResponse = client
        .post(
            route,
            Some(&GitHubCreateBlobRequest {
                content: Base64Standard.encode(content),
                encoding: "base64",
            }),
        )
        .await
        .map_err(operation_error)?;
    Ok(response.sha)
}

async fn create_commit(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    snapshot: &LocalBranchSnapshot,
    tree_sha: &str,
    parent_sha: &str,
) -> Result<String, CliError> {
    let route = format!(
        "/repos/{owner}/{repo}/git/commits",
        owner = config.owner,
        repo = config.repo,
    );
    let payload = unsigned_commit_payload(snapshot, tree_sha, parent_sha);
    let signature = publication_signature(
        &snapshot.profile,
        snapshot.existing_signature.as_ref(),
        payload.as_bytes(),
    )?;
    let commit: models::commits::GitCommitObject = client
        .post(
            route,
            Some(&GitHubCreateCommitRequest {
                message: snapshot.commit_message.clone(),
                tree: tree_sha.to_string(),
                parents: vec![parent_sha.to_string()],
                author: Some(snapshot.author.request.clone()),
                committer: Some(snapshot.committer.request.clone()),
                signature,
            }),
        )
        .await
        .map_err(operation_error)?;
    if matches!(snapshot.profile.signing.mode, TaskBoardGitSigningMode::Gpg)
        && !commit.verification.verified
    {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "task-board github created commit signature was not verified: {}",
            commit.verification.reason
        ))));
    }
    Ok(commit.sha)
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

async fn update_branch_ref(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    branch: &str,
    commit_sha: &str,
    mode: &BranchPublicationMode,
) -> Result<(), CliError> {
    let reference = Reference::Branch(branch.to_string());
    match mode {
        BranchPublicationMode::Update { .. } => {
            let route = format!(
                "/repos/{owner}/{repo}/git/refs/{reference}",
                owner = config.owner,
                repo = config.repo,
                reference = reference.ref_url(),
            );
            let _: models::repos::Ref = client
                .patch(
                    route,
                    Some(&GitHubUpdateRefRequest {
                        sha: commit_sha,
                        force: false,
                    }),
                )
                .await
                .map_err(operation_error)?;
        }
        BranchPublicationMode::Create { .. } => {
            client
                .repos(config.owner.as_str(), config.repo.as_str())
                .create_ref(&reference, commit_sha.to_string())
                .await
                .map_err(operation_error)?;
        }
    }
    Ok(())
}
