//! Git worktree lifecycle for per-session workspaces.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::Path;
use std::process::{Command, Output};

use thiserror::Error;
use tracing::{info, warn};

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
        let resolved_ref = match base_ref {
            Some(r) => r.to_string(),
            None => resolve_base_ref(origin)?,
        };
        let branch = layout.branch_ref();
        // NOTE: callers must serialize concurrent create() against the same origin — git's own index.lock surfaces as CreateFailed under contention.
        run_worktree_add(origin, layout, &branch, &resolved_ref)?;
        let post_add = (|| -> Result<(), WorktreeError> {
            fs::create_dir_all(layout.memory())?;
            fs::write(layout.origin_marker(), origin.to_string_lossy().as_bytes())?;
            Ok(())
        })();
        if let Err(err) = post_add {
            if let Err(rm_err) = run_worktree_remove(origin, layout) {
                warn!(%rm_err, "rollback: worktree remove failed");
            }
            if let Err(del_err) = run_branch_delete(origin, &branch) {
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
        run_worktree_remove(origin, layout)?;
        run_branch_delete(origin, &layout.branch_ref())?;
        if let Err(err) = fs::remove_dir_all(layout.session_root()) {
            warn!(%err, path = %layout.session_root().display(), "session root cleanup failed");
        }
        Ok(())
    }
}

fn run_worktree_add(
    origin: &Path,
    layout: &SessionLayout,
    branch: &str,
    resolved_ref: &str,
) -> Result<(), WorktreeError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(origin)
        .env("GIT_TERMINAL_PROMPT", "0")
        .args([
            "worktree",
            "add",
            "-b",
            branch,
            layout.workspace().to_string_lossy().as_ref(),
            resolved_ref,
        ])
        .output()?;
    if output.status.success() {
        return Ok(());
    }
    Err(WorktreeError::CreateFailed(
        String::from_utf8_lossy(&output.stderr).to_string(),
    ))
}

fn run_worktree_remove(origin: &Path, layout: &SessionLayout) -> Result<(), WorktreeError> {
    let remove = Command::new("git")
        .arg("-C")
        .arg(origin)
        .env("GIT_TERMINAL_PROMPT", "0")
        .args([
            "worktree",
            "remove",
            "--force",
            layout.workspace().to_string_lossy().as_ref(),
        ])
        .output()?;
    if remove.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&remove.stderr);
    if stderr.contains("not a working tree") {
        return Ok(());
    }
    Err(WorktreeError::RemoveFailed(stderr.to_string()))
}

fn run_branch_delete(origin: &Path, branch: &str) -> Result<(), WorktreeError> {
    let del = Command::new("git")
        .arg("-C")
        .arg(origin)
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(["branch", "-D", branch])
        .output()?;
    if del.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&del.stderr);
    if stderr.contains("not found") {
        return Ok(());
    }
    Err(WorktreeError::BranchDeleteFailed(stderr.to_string()))
}

fn resolve_base_ref(origin: &Path) -> Result<String, WorktreeError> {
    if let Some(remote) = current_branch_remote(origin)?
        && let Some(remote_head) = resolve_remote_head(origin, &remote)?
    {
        return Ok(remote_head);
    }
    let mut resolved_remote_heads = BTreeSet::new();
    for remote in git_lines(origin, &["remote"])? {
        if let Some(remote_head) = resolve_remote_head(origin, &remote)? {
            resolved_remote_heads.insert(remote_head);
        }
    }
    if resolved_remote_heads.len() == 1
        && let Some(remote_head) = resolved_remote_heads.into_iter().next()
    {
        return Ok(remote_head);
    }
    let head = git_output(origin, &["rev-parse", "--abbrev-ref", "HEAD"])?;
    if !head.status.success() {
        return Err(WorktreeError::CreateFailed("no HEAD".into()));
    }
    Ok(String::from_utf8_lossy(&head.stdout).trim().to_string())
}

fn current_branch_remote(origin: &Path) -> Result<Option<String>, WorktreeError> {
    let head = git_output(origin, &["symbolic-ref", "--quiet", "--short", "HEAD"])?;
    if !head.status.success() {
        return Ok(None);
    }
    let branch = String::from_utf8_lossy(&head.stdout).trim().to_string();
    if branch.is_empty() {
        return Ok(None);
    }
    let config_key = format!("branch.{branch}.remote");
    let remote = git_output(origin, &["config", "--get", &config_key])?;
    if !remote.status.success() {
        return Ok(None);
    }
    let remote = String::from_utf8_lossy(&remote.stdout).trim().to_string();
    if remote.is_empty() {
        return Ok(None);
    }
    Ok(Some(remote))
}

fn resolve_remote_head(origin: &Path, remote: &str) -> Result<Option<String>, WorktreeError> {
    let ref_name = format!("refs/remotes/{remote}/HEAD");
    let remote_head = git_output(origin, &["symbolic-ref", "--quiet", "--short", &ref_name])?;
    if !remote_head.status.success() {
        return Ok(None);
    }
    let remote_head = String::from_utf8_lossy(&remote_head.stdout)
        .trim()
        .to_string();
    if remote_head.is_empty() || remote_head == "HEAD" {
        return Ok(None);
    }
    Ok(Some(remote_head))
}

fn git_lines(origin: &Path, args: &[&str]) -> Result<Vec<String>, WorktreeError> {
    let output = git_output(origin, args)?;
    if !output.status.success() {
        return Ok(Vec::new());
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToOwned::to_owned)
        .collect())
}

fn git_output(origin: &Path, args: &[&str]) -> Result<Output, WorktreeError> {
    Ok(Command::new("git")
        .arg("-C")
        .arg(origin)
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(args)
        .output()?)
}

#[cfg(test)]
mod tests;
