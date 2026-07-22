use std::path::{Path, PathBuf};

use super::command::{GitCommandRunner, stdout};
use crate::git::{GitError, GitRepository, GitResult};

const MAX_INDEX_LIST_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitRepositoryCoordinates {
    worktree: PathBuf,
    git_dir: PathBuf,
    common_git_dir: PathBuf,
    object_directory: PathBuf,
    object_format: String,
}

impl GitRepositoryCoordinates {
    pub(crate) fn freeze(worktree: &Path) -> GitResult<Self> {
        let worktree = worktree
            .canonicalize()
            .map_err(|error| GitError::discover(worktree, error))?;
        if GitRepository::discover(&worktree)?.path() != worktree {
            return Err(GitError::unsafe_state(
                &worktree,
                "Git operation requires the exact checkout root",
            ));
        }
        let runner = GitCommandRunner::new(&worktree);
        let git_dir = canonical_git_path(
            &worktree,
            &runner,
            ["rev-parse", "--path-format=absolute", "--absolute-git-dir"],
        )?;
        let common_git_dir = canonical_git_path(
            &worktree,
            &runner,
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        )?;
        let object_directory = common_git_dir
            .join("objects")
            .canonicalize()
            .map_err(|error| GitError::read(&worktree, error))?;
        let object_format = stdout(&runner.read(["rev-parse", "--show-object-format"])?);
        let coordinates = Self {
            worktree,
            git_dir,
            common_git_dir,
            object_directory,
            object_format,
        };
        coordinates.require_shape()?;
        Ok(coordinates)
    }

    pub(crate) fn worktree(&self) -> &Path {
        &self.worktree
    }

    pub(crate) fn git_dir(&self) -> &Path {
        &self.git_dir
    }

    pub(crate) fn common_git_dir(&self) -> &Path {
        &self.common_git_dir
    }

    pub(crate) fn object_directory(&self) -> &Path {
        &self.object_directory
    }

    pub(crate) fn object_format(&self) -> &str {
        &self.object_format
    }

    pub(crate) fn runner(&self) -> GitResult<GitCommandRunner<'_>> {
        self.require_current()?;
        Ok(GitCommandRunner::routed(
            &self.worktree,
            &self.git_dir,
            &self.common_git_dir,
        ))
    }

    pub(crate) fn quarantine_runner(&self, quarantine: &Path) -> GitResult<GitCommandRunner<'_>> {
        self.runner()?
            .with_object_store(quarantine, &self.object_directory)
    }

    pub(crate) fn require_current(&self) -> GitResult<()> {
        let current = Self::freeze(&self.worktree)?;
        if current == *self {
            Ok(())
        } else {
            Err(GitError::unsafe_state(
                &self.worktree,
                "Git repository coordinates changed after they were frozen",
            ))
        }
    }

    pub(crate) fn require_dense_checkout(&self) -> GitResult<()> {
        let runner = self.runner()?;
        for key in ["core.sparseCheckout", "index.sparse"] {
            let output = runner.probe(["config", "--bool", "--get", key])?;
            if output.status.success() && stdout(&output) != "false" {
                return Err(sparse_error(&self.worktree));
            }
        }
        let output = runner.read_bounded_stdout(["ls-files", "-t", "-z"], MAX_INDEX_LIST_BYTES)?;
        if output
            .stdout
            .split(|byte| *byte == 0)
            .any(|row| row.starts_with(b"S "))
        {
            return Err(sparse_error(&self.worktree));
        }
        Ok(())
    }

    fn require_shape(&self) -> GitResult<()> {
        if !self.git_dir.is_absolute()
            || !self.common_git_dir.is_absolute()
            || !self.object_directory.is_absolute()
            || !matches!(self.object_format.as_str(), "sha1" | "sha256")
        {
            Err(GitError::unsafe_state(
                &self.worktree,
                "Git repository coordinates are noncanonical",
            ))
        } else {
            Ok(())
        }
    }
}

fn canonical_git_path<const N: usize>(
    worktree: &Path,
    runner: &GitCommandRunner<'_>,
    args: [&str; N],
) -> GitResult<PathBuf> {
    PathBuf::from(stdout(&runner.read(args)?))
        .canonicalize()
        .map_err(|error| GitError::read(worktree, error))
}

fn sparse_error(worktree: &Path) -> GitError {
    GitError::unsafe_state(
        worktree,
        "portable Git bundle operations reject sparse checkouts and skip-worktree entries",
    )
}
