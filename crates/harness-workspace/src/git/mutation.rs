#![allow(dead_code)]

use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use fs_err as fs;
use gix::index::write::Options as IndexWriteOptions;
use gix::progress::Discard;
use gix::refs::{
    FullName,
    transaction::{Change, PreviousValue, RefEdit, RefLog},
};
use gix::worktree::state::{self, checkout::Options};

use crate::git::{GitError, GitRepository, GitResult};
use crate::sandbox::hold_worktree_origin_grant;

use super::command::{GitCommandRunner, GitProcessLimits, stdout};
use super::source_repository_identity::{
    canonical_remote_slug, require_canonical_slug, require_no_git_operation,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LinkedWorktreeBackend {
    Gix,
}

pub(crate) const LINKED_WORKTREE_BACKEND: LinkedWorktreeBackend = LinkedWorktreeBackend::Gix;

/// Fetch and pin a fresh Harness session worktree to one immutable GitHub pull request head.
///
/// # Errors
/// Returns `GitError` unless the checkout is a clean `harness/*` linked worktree, exactly one
/// configured remote identifies `repository`, and GitHub's pull ref still resolves to
/// `expected_head`.
pub fn pin_github_pull_request_worktree(
    worktree: &Path,
    repository: &str,
    pull_request: u64,
    expected_head: &str,
) -> GitResult<()> {
    let _origin_grant = hold_worktree_origin_grant(worktree);
    require_pin_target(worktree, repository, pull_request, expected_head)?;
    let remote = matching_remote(worktree, repository)?;
    fetch_pull_request_head(worktree, &remote, pull_request, expected_head)?;
    require_clean_session_worktree(worktree)?;
    GitCommandRunner::new(worktree).mutation(["reset", "--hard", expected_head])?;
    let repository = GitRepository::discover(worktree)?;
    if repository.resolve_revision_to_commit("HEAD")? != expected_head
        || repository.has_changes_including_untracked()?
    {
        return Err(GitError::unsafe_state(
            worktree,
            "pull request worktree did not settle on the frozen clean head",
        ));
    }
    Ok(())
}

fn require_pin_target(
    worktree: &Path,
    repository: &str,
    pull_request: u64,
    expected_head: &str,
) -> GitResult<()> {
    require_canonical_slug(worktree, repository)?;
    if pull_request == 0
        || expected_head.len() != 40
        || !expected_head.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(GitError::unsafe_state(
            worktree,
            "pull request worktree target is noncanonical",
        ));
    }
    require_clean_session_worktree(worktree)
}

fn require_clean_session_worktree(worktree: &Path) -> GitResult<()> {
    let repository = GitRepository::discover(worktree)?;
    let canonical = worktree
        .canonicalize()
        .map_err(|error| GitError::discover(worktree, error))?;
    if repository.path() != canonical {
        return Err(GitError::unsafe_state(
            worktree,
            "pull request target must be an exact worktree root",
        ));
    }
    require_no_git_operation(worktree)?;
    let branch =
        stdout(&GitCommandRunner::new(worktree).read(["symbolic-ref", "--short", "HEAD"])?);
    if !branch.starts_with("harness/") || repository.has_changes_including_untracked()? {
        return Err(GitError::unsafe_state(
            worktree,
            "pull request target must be a clean Harness session branch",
        ));
    }
    Ok(())
}

fn matching_remote(worktree: &Path, repository: &str) -> GitResult<String> {
    let runner = GitCommandRunner::new(worktree);
    let output = runner.read_bounded_stdout(["remote"], 16 * 1024)?;
    let mut matches = Vec::new();
    for remote in stdout(&output).lines().filter(|name| !name.is_empty()) {
        let key = format!("remote.{remote}.url");
        let configured = runner.read_bounded_stdout(["config", "--get", &key], 4 * 1024)?;
        if canonical_remote_slug(&stdout(&configured)).as_deref() == Some(repository) {
            matches.push(remote.to_string());
        }
    }
    match matches.as_slice() {
        [remote] => Ok(remote.clone()),
        [] => Err(GitError::unsafe_state(
            worktree,
            "no configured remote matches the frozen pull request repository",
        )),
        _ => Err(GitError::unsafe_state(
            worktree,
            "multiple configured remotes match the frozen pull request repository",
        )),
    }
}

fn fetch_pull_request_head(
    worktree: &Path,
    remote: &str,
    pull_request: u64,
    expected_head: &str,
) -> GitResult<()> {
    let source = format!("refs/pull/{pull_request}/head");
    let target = format!("refs/harness/task-board/pull/{pull_request}/{expected_head}");
    let refspec = format!("+{source}:{target}");
    GitCommandRunner::new(worktree).mutation_resource_limited_with_input(
        [
            "fetch",
            "--no-tags",
            "--no-recurse-submodules",
            remote,
            &refspec,
        ],
        b"",
        256 * 1024,
        GitProcessLimits {
            wall_time: Duration::from_mins(2),
            cpu_seconds: 90,
            address_space_bytes: 2 * 1024 * 1024 * 1024,
            alloc_limit_bytes: 512 * 1024 * 1024,
            file_bytes: 4 * 1024 * 1024 * 1024,
        },
    )?;
    let repository = GitRepository::discover(worktree)?;
    if repository.resolve_revision_to_commit(&target)? != expected_head {
        return Err(GitError::unsafe_state(
            worktree,
            "GitHub pull ref changed from the frozen head before worker launch",
        ));
    }
    Ok(())
}

/// Create a linked worktree for `branch_name` at `worktree_path`.
///
/// # Errors
/// Returns `GitError` if the repository cannot be opened, has no committer
/// identity to fall back on, or if writing the worktree and its branch fails.
pub fn create_linked_worktree(
    repo_path: &Path,
    worktree_name: &str,
    worktree_path: &Path,
    branch_name: &str,
    base_commit: &str,
) -> GitResult<()> {
    let mut repo = open(repo_path)?;
    repo.committer_or_set_generic_fallback()
        .map_err(|error| GitError::mutation(repo_path, error))?;
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
    fs::create_dir_all(&worktree_git_dir).map_err(|error| GitError::mutation(repo_path, error))?;

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

    let relative_common =
        pathdiff::diff_paths(&common_dir, &worktree_git_dir).unwrap_or_else(|| common_dir.clone());
    fs::write(
        worktree_git_dir.join("commondir"),
        format!("{}\n", relative_common.display()),
    )
    .map_err(|error| GitError::mutation(repo_path, error))?;

    fs::create_dir_all(worktree_path).map_err(|error| GitError::mutation(repo_path, error))?;
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

    let mut index = repo
        .index_from_tree(&tree_id)
        .map_err(|error| GitError::mutation(error_path, error))?;

    let workdir = repo
        .workdir()
        .ok_or_else(|| GitError::mutation(error_path, "repository has no work directory"))?;

    let options = Options {
        overwrite_existing: true,
        ..Default::default()
    };

    state::checkout(
        &mut index,
        workdir,
        repo.objects.clone().into_arc().expect("object cache"),
        &Discard,
        &Discard,
        &AtomicBool::new(false),
        options,
    )
    .map_err(|error| GitError::mutation(error_path, error))?;

    index
        .write(IndexWriteOptions::default())
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
        fs::remove_dir_all(worktree_path).map_err(|error| GitError::mutation(repo_path, error))?;
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

    let full_name: FullName = ref_name
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
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    use tempfile::tempdir;

    use super::{
        LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend, create_linked_worktree,
        pin_github_pull_request_worktree,
    };

    #[test]
    fn linked_worktree_backend_defaults_to_gix() {
        assert_eq!(LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend::Gix);
    }

    #[test]
    fn pull_request_pin_fetches_exact_head_without_moving_origin_checkout() {
        let temp = tempdir().expect("tempdir");
        let origin = temp.path().join("origin");
        let remote = temp.path().join("remote.git");
        let session = temp.path().join("session");
        fs::create_dir(&origin).expect("origin directory");
        git(&origin, &["init", "-b", "main"]);
        git(&origin, &["config", "user.name", "Harness Test"]);
        git(&origin, &["config", "user.email", "test@example.com"]);
        fs::write(origin.join("README.md"), "base\n").expect("base file");
        git(&origin, &["add", "README.md"]);
        git(
            &origin,
            &["-c", "commit.gpgsign=false", "commit", "-m", "base"],
        );
        let base = git_stdout(&origin, &["rev-parse", "HEAD"]);
        git(temp.path(), &["init", "--bare", path(&remote)]);
        git(&origin, &["remote", "add", "upstream", path(&remote)]);
        git(&origin, &["push", "upstream", "HEAD:refs/heads/main"]);
        fs::write(origin.join("README.md"), "pull request\n").expect("pr file");
        git(&origin, &["add", "README.md"]);
        git(
            &origin,
            &["-c", "commit.gpgsign=false", "commit", "-m", "pull request"],
        );
        let pull_head = git_stdout(&origin, &["rev-parse", "HEAD"]);
        git(&origin, &["push", "upstream", "HEAD:refs/pull/17/head"]);
        git(&origin, &["reset", "--hard", &base]);
        git(
            &origin,
            &[
                "remote",
                "set-url",
                "upstream",
                "git@github.com:acme/widgets.git",
            ],
        );
        let rewrite = format!("url.file://{}/.insteadOf", remote.display());
        git(
            &origin,
            &["config", &rewrite, "git@github.com:acme/widgets.git"],
        );
        create_linked_worktree(&origin, "session-1", &session, "harness/session-1", &base)
            .expect("session worktree");

        pin_github_pull_request_worktree(&session, "acme/widgets", 17, &pull_head)
            .expect("pin pull request head");

        assert_eq!(git_stdout(&session, &["rev-parse", "HEAD"]), pull_head);
        assert_eq!(git_stdout(&origin, &["rev-parse", "HEAD"]), base);
        assert_eq!(
            git_stdout(&session, &["symbolic-ref", "--short", "HEAD"]),
            "harness/session-1"
        );
        assert!(git_stdout(&session, &["status", "--porcelain"]).is_empty());
    }

    fn git(repository: &Path, args: &[&str]) {
        let output = Command::new("git")
            .arg("-C")
            .arg(repository)
            .args(args)
            .output()
            .expect("run git");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn git_stdout(repository: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(repository)
            .args(args)
            .output()
            .expect("run git");
        assert!(output.status.success(), "git {args:?}");
        String::from_utf8(output.stdout)
            .expect("git output")
            .trim()
            .to_string()
    }

    fn path(path: &Path) -> &str {
        path.to_str().expect("UTF-8 fixture path")
    }
}
