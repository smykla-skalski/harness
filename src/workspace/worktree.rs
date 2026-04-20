//! Git worktree lifecycle for per-session workspaces.

use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;

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
    let origin_head = Command::new("git")
        .arg("-C")
        .arg(origin)
        .args(["rev-parse", "--abbrev-ref", "origin/HEAD"])
        .output()?;
    if origin_head.status.success() {
        let s = String::from_utf8_lossy(&origin_head.stdout)
            .trim()
            .to_string();
        if !s.is_empty() && s != "HEAD" {
            return Ok(s);
        }
    }
    let head = Command::new("git")
        .arg("-C")
        .arg(origin)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()?;
    if !head.status.success() {
        return Err(WorktreeError::CreateFailed("no HEAD".into()));
    }
    Ok(String::from_utf8_lossy(&head.stdout).trim().to_string())
}

#[cfg(test)]
mod tests;
