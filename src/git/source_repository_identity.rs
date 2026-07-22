use std::path::{Path, PathBuf};

use super::command::{GitCommandRunner, stdout};
use crate::git::{GitError, GitRepository, GitResult};
use crate::task_board::normalize_repository_slug;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum GitSourceRepositoryProof {
    ConfiguredCheckout { checkout: PathBuf },
    CanonicalOrigin,
}

impl GitSourceRepositoryProof {
    pub(super) fn configured(checkout: &Path) -> GitResult<Self> {
        let checkout = exact_checkout_root(checkout)?;
        Ok(Self::ConfiguredCheckout { checkout })
    }

    pub(super) fn require(
        &self,
        worktree: &Path,
        repository: &str,
    ) -> GitResult<()> {
        require_canonical_slug(worktree, repository)?;
        match self {
            Self::ConfiguredCheckout { checkout } => {
                require_same_common_git_dir(worktree, checkout)
            }
            Self::CanonicalOrigin => require_canonical_origin(worktree, repository),
        }
    }
}

pub(super) fn exact_checkout_root(path: &Path) -> GitResult<PathBuf> {
    let canonical = path
        .canonicalize()
        .map_err(|error| GitError::discover(path, error))?;
    if GitRepository::discover(&canonical)?.path() == canonical {
        Ok(canonical)
    } else {
        Err(GitError::unsafe_state(
            path,
            "source repository proof requires an exact checkout root",
        ))
    }
}

pub(super) fn require_no_git_operation(repository: &Path) -> GitResult<()> {
    for marker in [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "BISECT_LOG",
        "rebase-apply",
        "rebase-merge",
        "sequencer",
    ] {
        let path = PathBuf::from(stdout(
            &GitCommandRunner::new(repository).read([
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                marker,
            ])?,
        ));
        if path.exists() {
            return Err(GitError::unsafe_state(
                repository,
                "source repository has an in-progress git operation",
            ));
        }
    }
    Ok(())
}

fn require_canonical_slug(path: &Path, repository: &str) -> GitResult<()> {
    if repository.len() <= 2_048
        && normalize_repository_slug(Some(repository)).as_deref() == Some(repository)
    {
        Ok(())
    } else {
        Err(GitError::unsafe_state(
            path,
            "source repository identity is noncanonical",
        ))
    }
}

fn require_same_common_git_dir(worktree: &Path, configured: &Path) -> GitResult<()> {
    let worktree_common = common_git_dir(worktree)?;
    let configured_common = common_git_dir(configured)?;
    if worktree_common == configured_common {
        Ok(())
    } else {
        Err(GitError::unsafe_state(
            worktree,
            "source worktree belongs to another configured repository",
        ))
    }
}

fn common_git_dir(repository: &Path) -> GitResult<PathBuf> {
    let output = GitCommandRunner::new(repository)
        .read(["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    PathBuf::from(stdout(&output))
        .canonicalize()
        .map_err(|error| GitError::read(repository, error))
}

fn require_canonical_origin(worktree: &Path, repository: &str) -> GitResult<()> {
    let output = GitCommandRunner::new(worktree)
        .read_bounded_stdout(["remote", "get-url", "origin"], 4 * 1024)?;
    let origin = stdout(&output);
    if canonical_remote_slug(&origin).as_deref() == Some(repository) {
        Ok(())
    } else {
        Err(GitError::unsafe_state(
            worktree,
            "source worktree origin does not match the frozen repository",
        ))
    }
}

fn canonical_remote_slug(origin: &str) -> Option<String> {
    let value = origin.trim();
    let path = if let Some((scheme, remainder)) = value.split_once("://") {
        let (authority, path) = remainder.split_once('/')?;
        let exact_authority = match scheme {
            "https" => authority == "github.com",
            "ssh" => authority == "git@github.com",
            _ => false,
        };
        if !exact_authority {
            return None;
        }
        path
    } else {
        let (authority, path) = value.split_once(':')?;
        if authority != "git@github.com" {
            return None;
        }
        path
    };
    let path = path.trim_end_matches('/').strip_suffix(".git").unwrap_or(path);
    normalize_repository_slug(Some(path))
}

#[cfg(test)]
mod tests {
    use super::canonical_remote_slug;

    #[test]
    fn canonical_remote_slug_accepts_network_git_forms_only() {
        for origin in [
            "https://github.com/Example/Widgets.git",
            "ssh://git@github.com/example/widgets.git",
            "git@github.com:example/widgets.git",
        ] {
            assert_eq!(canonical_remote_slug(origin).as_deref(), Some("example/widgets"));
        }
        for origin in [
            "/tmp/example/widgets",
            "file:///tmp/example/widgets",
            "https://evil.invalid/example/widgets.git",
            "ssh://git@evil.invalid/example/widgets.git",
            "https://github.com/example/widgets/extra",
            "github.com:example/widgets",
        ] {
            assert_eq!(canonical_remote_slug(origin), None);
        }
    }
}
