use std::fs;
use std::path::{Path, PathBuf};

use harness_protocol::daemon::summaries::AgentWorkspaceAvailability;
use harness_workspace::git::identity::resolve_git_checkout_identity;

#[derive(Clone, Copy)]
pub(crate) struct RecordedCheckout<'a> {
    pub project_dir: Option<&'a str>,
    pub repository_root: Option<&'a str>,
    pub is_worktree: bool,
    pub worktree_name: Option<&'a str>,
}

pub(crate) fn recorded_checkout_availability(
    checkout: RecordedCheckout<'_>,
) -> Result<AgentWorkspaceAvailability, String> {
    let Some(project_dir) = checkout.project_dir.filter(|path| !path.trim().is_empty()) else {
        return Err("recorded checkout has no project directory".to_string());
    };
    validate_worktree_metadata(checkout)?;
    let Some(checkout_root) = existing_directory(project_dir)? else {
        return Ok(AgentWorkspaceAvailability::MissingWorktree);
    };
    let Some(repository_root) = checkout
        .repository_root
        .filter(|path| !path.trim().is_empty())
    else {
        return Ok(if checkout.is_worktree {
            AgentWorkspaceAvailability::MissingWorktree
        } else {
            AgentWorkspaceAvailability::Available
        });
    };
    let Some(repository_root) = existing_directory(repository_root)? else {
        return Ok(AgentWorkspaceAvailability::MissingWorktree);
    };
    if checkout.is_worktree {
        return Ok(worktree_matches(
            &checkout_root,
            &repository_root,
            checkout.worktree_name,
        ));
    }
    if checkout_root != repository_root {
        return Ok(AgentWorkspaceAvailability::MissingWorktree);
    }
    let Some(identity) = resolve_git_checkout_identity(&checkout_root) else {
        return Ok(AgentWorkspaceAvailability::Available);
    };
    Ok(
        if !identity.is_worktree()
            && identity.checkout_root == checkout_root
            && identity.repository_root == repository_root
        {
            AgentWorkspaceAvailability::Available
        } else {
            AgentWorkspaceAvailability::MissingWorktree
        },
    )
}

fn validate_worktree_metadata(checkout: RecordedCheckout<'_>) -> Result<(), String> {
    if !checkout.is_worktree {
        return Ok(());
    }
    if checkout
        .repository_root
        .is_none_or(|path| path.trim().is_empty())
    {
        return Err("recorded worktree has no repository root".to_string());
    }
    if checkout
        .worktree_name
        .is_none_or(|name| name.trim().is_empty())
    {
        return Err("recorded worktree has no worktree name".to_string());
    }
    Ok(())
}

fn existing_directory(path: &str) -> Result<Option<PathBuf>, String> {
    let path = Path::new(path);
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("cannot inspect {}: {error}", path.display())),
    };
    if !metadata.is_dir() {
        return Ok(None);
    }
    path.canonicalize()
        .map(Some)
        .map_err(|error| format!("cannot resolve {}: {error}", path.display()))
}

fn worktree_matches(
    checkout_root: &Path,
    repository_root: &Path,
    worktree_name: Option<&str>,
) -> AgentWorkspaceAvailability {
    let matches = resolve_git_checkout_identity(checkout_root).is_some_and(|identity| {
        identity.is_worktree()
            && identity.checkout_root == checkout_root
            && identity.repository_root == repository_root
            && worktree_name.is_none_or(|expected| identity.worktree_name() == Some(expected))
    });
    if matches {
        AgentWorkspaceAvailability::Available
    } else {
        AgentWorkspaceAvailability::MissingWorktree
    }
}
