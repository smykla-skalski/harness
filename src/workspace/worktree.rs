//! Git worktree lifecycle for per-session workspaces.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::Path;

use thiserror::Error;
use tracing::{info, warn};

use crate::git::GitRepository;
use crate::git::mutation::{create_linked_worktree, delete_local_branch, remove_linked_worktree};

use super::layout::SessionLayout;

#[derive(Debug, Error)]
pub enum WorktreeError {
    #[error("worktree create failed: {0}")]
    CreateFailed(String),
    #[error("worktree remove failed: {0}")]
    RemoveFailed(String),
    #[error("branch delete failed: {0}")]
    BranchDeleteFailed(String),
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
}

pub struct WorktreeController;

impl WorktreeController {
    /// # Errors
    /// Returns `WorktreeError::CreateFailed` when git rejects the worktree creation,
    /// `WorktreeError::Io` on filesystem errors.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub fn create(
        origin: &Path,
        layout: &SessionLayout,
        base_ref: Option<&str>,
    ) -> Result<(), WorktreeError> {
        let repository = GitRepository::discover(origin)
            .map_err(|error| WorktreeError::CreateFailed(error.to_string()))?;
        let resolved_ref = match base_ref {
            Some(r) => r.to_string(),
            None => resolve_base_ref(&repository)?,
        };
        let base_commit = repository
            .resolve_revision_to_commit(&resolved_ref)
            .map_err(|error| WorktreeError::CreateFailed(error.to_string()))?;
        let branch = layout.branch_ref();
        fs::create_dir_all(layout.session_root())?;
        // NOTE: callers must serialize concurrent create() against the same origin — git's own index.lock surfaces as CreateFailed under contention.
        create_linked_worktree(
            repository.path(),
            &layout.session_id,
            &layout.workspace(),
            &branch,
            &base_commit,
        )
        .map_err(|error| WorktreeError::CreateFailed(error.to_string()))?;
        let post_add = (|| -> Result<(), WorktreeError> {
            fs::create_dir_all(layout.memory())?;
            fs::write(layout.origin_marker(), origin.to_string_lossy().as_bytes())?;
            Ok(())
        })();
        if let Err(err) = post_add {
            if let Err(rm_err) = run_worktree_remove(repository.path(), layout) {
                warn!(%rm_err, "rollback: worktree remove failed");
            }
            if let Err(del_err) = run_branch_delete(repository.path(), &branch) {
                warn!(%del_err, "rollback: branch delete failed");
            }
            return Err(err);
        }
        info!(path = %layout.workspace().display(), branch = %branch, "created worktree");
        Ok(())
    }

    /// # Errors
    /// Returns `WorktreeError::RemoveFailed`/`BranchDeleteFailed` on git errors,
    /// `WorktreeError::Io` on filesystem errors.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub fn destroy(origin: &Path, layout: &SessionLayout) -> Result<(), WorktreeError> {
        let repository = GitRepository::discover(origin)
            .map_err(|error| WorktreeError::RemoveFailed(error.to_string()))?;
        run_worktree_remove(repository.path(), layout)?;
        run_branch_delete(repository.path(), &layout.branch_ref())?;
        if let Err(err) = fs::remove_dir_all(layout.session_root()) {
            warn!(%err, path = %layout.session_root().display(), "session root cleanup failed");
        }
        Ok(())
    }
}

fn run_worktree_remove(origin: &Path, layout: &SessionLayout) -> Result<(), WorktreeError> {
    remove_linked_worktree(origin, &layout.session_id, &layout.workspace())
        .map_err(|error| WorktreeError::RemoveFailed(error.to_string()))
}

fn run_branch_delete(origin: &Path, branch: &str) -> Result<(), WorktreeError> {
    delete_local_branch(origin, branch)
        .map_err(|error| WorktreeError::BranchDeleteFailed(error.to_string()))
}

fn resolve_base_ref(repository: &GitRepository) -> Result<String, WorktreeError> {
    if let Some(remote) = current_branch_remote(repository)?
        && let Some(remote_head) = resolve_remote_head(repository, &remote)?
    {
        return Ok(remote_head);
    }
    let mut resolved_remote_heads = BTreeSet::new();
    for remote in repository
        .remote_names()
        .map_err(|error| WorktreeError::CreateFailed(error.to_string()))?
    {
        if let Some(remote_head) = resolve_remote_head(repository, &remote)? {
            resolved_remote_heads.insert(remote_head);
        }
    }
    if resolved_remote_heads.len() == 1
        && let Some(remote_head) = resolved_remote_heads.into_iter().next()
    {
        return Ok(remote_head);
    }
    repository
        .head_branch_short_name()
        .map_err(|error| WorktreeError::CreateFailed(error.to_string()))?
        .ok_or_else(|| WorktreeError::CreateFailed("no HEAD".into()))
}

fn current_branch_remote(repository: &GitRepository) -> Result<Option<String>, WorktreeError> {
    repository
        .current_branch_remote_name()
        .map_err(|error| WorktreeError::CreateFailed(error.to_string()))
}

fn resolve_remote_head(
    repository: &GitRepository,
    remote: &str,
) -> Result<Option<String>, WorktreeError> {
    let remote_head = repository
        .remote_head_short_name(remote)
        .map_err(|error| WorktreeError::CreateFailed(error.to_string()))?;
    Ok(remote_head.filter(|name| !name.is_empty() && name != "HEAD"))
}

#[cfg(test)]
mod tests;
