#![allow(dead_code)]

use std::path::Path;

use git2::{BranchType, Oid, Repository, WorktreePruneOptions, build::CheckoutBuilder};

use crate::git::{GitError, GitResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LinkedWorktreeBackend {
    Git2,
}

pub(crate) const LINKED_WORKTREE_BACKEND: LinkedWorktreeBackend = LinkedWorktreeBackend::Git2;

pub(crate) fn create_linked_worktree(
    repo_path: &Path,
    worktree_name: &str,
    worktree_path: &Path,
    branch_name: &str,
    base_commit: &str,
) -> GitResult<()> {
    let repo = open(repo_path)?;
    let commit = repo
        .find_commit(
            Oid::from_str(base_commit).map_err(|error| GitError::mutation(repo_path, error))?,
        )
        .map_err(|error| GitError::mutation(repo_path, error))?;
    let branch = repo
        .branch(branch_name, &commit, false)
        .map_err(|error| GitError::mutation(repo_path, error))?;
    let reference = branch.into_reference();
    let mut options = git2::WorktreeAddOptions::new();
    options.reference(Some(&reference));
    let worktree = repo
        .worktree(worktree_name, worktree_path, Some(&options))
        .map_err(|error| GitError::mutation(repo_path, error))?;
    let branch_ref = format!("refs/heads/{branch_name}");
    Repository::open_from_worktree(&worktree)
        .and_then(|worktree_repo| {
            let object = worktree_repo.revparse_single(&branch_ref)?;
            worktree_repo.checkout_tree(&object, Some(CheckoutBuilder::new().force()))?;
            worktree_repo.set_head(&branch_ref)?;
            Ok(())
        })
        .map_err(|error| GitError::mutation(repo_path, error))
}

pub(crate) fn remove_linked_worktree(
    repo_path: &Path,
    worktree_name: &str,
    worktree_path: &Path,
) -> GitResult<()> {
    let repo = open(repo_path)?;
    let Some(worktree) = find_worktree(&repo, worktree_name, worktree_path)? else {
        return Ok(());
    };
    let mut options = WorktreePruneOptions::new();
    options.valid(true).locked(true).working_tree(true);
    worktree
        .prune(Some(&mut options))
        .map_err(|error| GitError::mutation(repo_path, error))
}

pub(crate) fn delete_local_branch(repo_path: &Path, branch_name: &str) -> GitResult<()> {
    let repo = open(repo_path)?;
    let Ok(mut branch) = repo.find_branch(branch_name, BranchType::Local) else {
        return Ok(());
    };
    branch
        .delete()
        .map_err(|error| GitError::mutation(repo_path, error))
}

fn open(path: &Path) -> GitResult<Repository> {
    Repository::open(path).map_err(|error| GitError::open(path, error))
}

fn find_worktree(
    repo: &Repository,
    worktree_name: &str,
    worktree_path: &Path,
) -> GitResult<Option<git2::Worktree>> {
    if let Ok(worktree) = repo.find_worktree(worktree_name) {
        return Ok(Some(worktree));
    }
    let names = repo
        .worktrees()
        .map_err(|error| GitError::mutation(repo.path(), error))?;
    for name in names.iter().flatten() {
        let worktree = repo
            .find_worktree(name)
            .map_err(|error| GitError::mutation(repo.path(), error))?;
        if worktree.path() == worktree_path {
            return Ok(Some(worktree));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::{LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend};

    #[test]
    fn linked_worktree_backend_defaults_to_git2() {
        assert_eq!(LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend::Git2);
    }
}
