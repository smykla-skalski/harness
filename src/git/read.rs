#![allow(dead_code)]

use std::path::{Path, PathBuf};

use crate::git::{GitError, GitResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitRepository {
    path: PathBuf,
}

impl GitRepository {
    #[must_use]
    pub(crate) fn from_path(path: &Path) -> Self {
        Self {
            path: path.canonicalize().unwrap_or_else(|_| path.to_path_buf()),
        }
    }

    pub(crate) fn discover(path: &Path) -> GitResult<Self> {
        let repo = gix::discover(path).map_err(|error| GitError::discover(path, error))?;
        let resolved = repo
            .workdir()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| repo.common_dir().to_path_buf());
        Ok(Self::from_path(&resolved))
    }

    #[must_use]
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn open_gix(&self) -> GitResult<gix::Repository> {
        gix::open(self.path()).map_err(|error| GitError::open(self.path(), error))
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    use fs_err as fs;
    use tempfile::tempdir;

    use super::GitRepository;

    fn init_repo(root: &std::path::Path) {
        fs::create_dir_all(root).expect("create repo");
        let init = Command::new("git")
            .arg("init")
            .arg("-q")
            .arg(root)
            .status()
            .expect("git init");
        assert!(init.success(), "git init should succeed");
    }

    #[test]
    fn discover_resolves_repo_root_from_nested_path() {
        let tmp = tempdir().expect("tempdir");
        let repo_root = tmp.path().join("repo");
        let nested = repo_root.join("nested/deeper");
        init_repo(&repo_root);
        fs::create_dir_all(&nested).expect("create nested");

        let repo = GitRepository::discover(&nested).expect("discover repo");

        assert_eq!(
            repo.path(),
            repo_root.canonicalize().expect("canonicalize repo root")
        );
    }
}
