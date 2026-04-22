#![allow(dead_code)]

use std::path::Path;

use fs_err as fs;
use gix::refs::transaction::{Change, PreviousValue, RefEdit, RefLog};

use crate::git::{GitError, GitResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LinkedWorktreeBackend {
    Gix,
}

pub(crate) const LINKED_WORKTREE_BACKEND: LinkedWorktreeBackend = LinkedWorktreeBackend::Gix;

pub(crate) fn create_linked_worktree(
    repo_path: &Path,
    worktree_name: &str,
    worktree_path: &Path,
    branch_name: &str,
    base_commit: &str,
) -> GitResult<()> {
    let repo = open(repo_path)?;
    let common_dir = repo.common_dir().to_path_buf();

    let commit_id = repo
        .rev_parse_single(base_commit.as_bytes())
        .map_err(|error| GitError::mutation(repo_path, error))?
        .detach();

    repo.reference(
        format!("refs/heads/{branch_name}"),
        commit_id,
        PreviousValue::MustNotExist,
        format!("branch: Created from {base_commit}"),
    )
    .map_err(|error| GitError::mutation(repo_path, error))?;

    let worktree_git_dir = common_dir.join("worktrees").join(worktree_name);
    fs::create_dir_all(&worktree_git_dir)
        .map_err(|error| GitError::mutation(repo_path, error))?;

    let worktree_dot_git = worktree_path.join(".git");
    fs::write(
        worktree_git_dir.join("gitdir"),
        format!("{}\n", worktree_dot_git.display()),
    )
    .map_err(|error| GitError::mutation(repo_path, error))?;

    fs::write(
        worktree_git_dir.join("HEAD"),
        format!("ref: refs/heads/{branch_name}\n"),
    )
    .map_err(|error| GitError::mutation(repo_path, error))?;

    let relative_common = pathdiff::diff_paths(&common_dir, &worktree_git_dir)
        .unwrap_or_else(|| common_dir.clone());
    fs::write(
        worktree_git_dir.join("commondir"),
        format!("{}\n", relative_common.display()),
    )
    .map_err(|error| GitError::mutation(repo_path, error))?;

    fs::create_dir_all(worktree_path)
        .map_err(|error| GitError::mutation(repo_path, error))?;
    fs::write(
        &worktree_dot_git,
        format!("gitdir: {}\n", worktree_git_dir.display()),
    )
    .map_err(|error| GitError::mutation(repo_path, error))?;

    let worktree_repo =
        gix::open(worktree_path).map_err(|error| GitError::mutation(repo_path, error))?;

    checkout_head(&worktree_repo, repo_path)?;

    Ok(())
}

fn checkout_head(repo: &gix::Repository, error_path: &Path) -> GitResult<()> {
    let head_commit = repo
        .head_commit()
        .map_err(|error| GitError::mutation(error_path, error))?;
    let tree_id = head_commit
        .tree_id()
        .map_err(|error| GitError::mutation(error_path, error))?;

    let index = repo
        .index_from_tree(&tree_id)
        .map_err(|error| GitError::mutation(error_path, error))?;

    let workdir = repo
        .workdir()
        .ok_or_else(|| GitError::mutation(error_path, "repository has no work directory"))?;

    let options = gix::worktree::state::checkout::Options {
        overwrite_existing: true,
        ..Default::default()
    };

    gix::worktree::state::checkout(
        &mut index.into(),
        workdir,
        repo.objects.clone().into_arc().expect("object cache"),
        &gix::progress::Discard,
        &gix::progress::Discard,
        &std::sync::atomic::AtomicBool::new(false),
        options,
    )
    .map_err(|error| GitError::mutation(error_path, error))?;

    Ok(())
}

pub(crate) fn remove_linked_worktree(
    repo_path: &Path,
    worktree_name: &str,
    worktree_path: &Path,
) -> GitResult<()> {
    let repo = open(repo_path)?;
    let common_dir = repo.common_dir();
    let worktree_git_dir = common_dir.join("worktrees").join(worktree_name);

    if worktree_path.exists() {
        fs::remove_dir_all(worktree_path)
            .map_err(|error| GitError::mutation(repo_path, error))?;
    }

    if worktree_git_dir.exists() {
        fs::remove_dir_all(&worktree_git_dir)
            .map_err(|error| GitError::mutation(repo_path, error))?;
    }

    Ok(())
}

pub(crate) fn delete_local_branch(repo_path: &Path, branch_name: &str) -> GitResult<()> {
    let repo = open(repo_path)?;
    let ref_name = format!("refs/heads/{branch_name}");

    let full_name: gix::refs::FullName = ref_name
        .try_into()
        .map_err(|error| GitError::mutation(repo_path, error))?;

    if repo.try_find_reference(&full_name).ok().flatten().is_none() {
        return Ok(());
    }

    repo.edit_reference(RefEdit {
        change: Change::Delete {
            expected: PreviousValue::Any,
            log: RefLog::AndReference,
        },
        name: full_name,
        deref: false,
    })
    .map_err(|error| GitError::mutation(repo_path, error))?;

    Ok(())
}

fn open(path: &Path) -> GitResult<gix::Repository> {
    gix::open(path).map_err(|error| GitError::open(path, error))
}

#[cfg(test)]
mod tests {
    use super::{LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend};

    #[test]
    fn linked_worktree_backend_defaults_to_gix() {
        assert_eq!(LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend::Gix);
    }
}
