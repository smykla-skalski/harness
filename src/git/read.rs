#![allow(dead_code)]

use std::path::{Path, PathBuf};

use gix::refs::TargetRef;
use gix::remote;

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
            .map_or_else(|| repo.common_dir().to_path_buf(), Path::to_path_buf);
        Ok(Self::from_path(&resolved))
    }

    #[must_use]
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn open_gix(&self) -> GitResult<gix::Repository> {
        gix::open(self.path()).map_err(|error| GitError::open(self.path(), error))
    }

    pub(crate) fn head_branch_short_name(&self) -> GitResult<Option<String>> {
        let repo = self.open_gix()?;
        repo.head_name()
            .map(|name| name.map(|name| name.shorten().to_string()))
            .map_err(|error| GitError::read(self.path(), error))
    }

    pub(crate) fn current_branch_remote_name(&self) -> GitResult<Option<String>> {
        let repo = self.open_gix()?;
        let Some(head_name) = repo
            .head_name()
            .map_err(|error| GitError::read(self.path(), error))?
        else {
            return Ok(None);
        };
        let branch_name = head_name.shorten().to_string();
        Ok(repo
            .branch_remote_name(branch_name.as_str(), remote::Direction::Fetch)
            .and_then(|name| name.as_symbol().map(ToOwned::to_owned)))
    }

    pub(crate) fn remote_head_short_name(&self, remote_name: &str) -> GitResult<Option<String>> {
        let repo = self.open_gix()?;
        let reference_name = format!("refs/remotes/{remote_name}/HEAD");
        let reference = repo
            .try_find_reference(reference_name.as_str())
            .map_err(|error| GitError::read(self.path(), error))?;
        let Some(reference) = reference else {
            return Ok(None);
        };
        match reference.target() {
            TargetRef::Symbolic(name) => Ok(Some(name.shorten().to_string())),
            TargetRef::Object(_) => Ok(None),
        }
    }

    pub(crate) fn remote_names(&self) -> GitResult<Vec<String>> {
        let repo = self.open_gix()?;
        Ok(repo
            .remote_names()
            .into_iter()
            .map(|name| name.to_string())
            .collect())
    }

    pub(crate) fn resolve_revision_to_commit(&self, spec: &str) -> GitResult<String> {
        let repo = self.open_gix()?;
        let id = repo
            .rev_parse_single(spec.as_bytes())
            .map_err(|error| GitError::read(self.path(), error))?;
        Ok(id.detach().to_hex().to_string())
    }

    pub(crate) fn is_dirty(&self) -> GitResult<bool> {
        let repo = self.open_gix()?;
        repo.is_dirty()
            .map_err(|error| GitError::read(self.path(), error))
    }

    pub(crate) fn short_head_sha(&self, hex_len: usize) -> GitResult<Option<String>> {
        let repo = self.open_gix()?;
        let head = repo
            .head()
            .map_err(|error| GitError::read(self.path(), error))?;
        let Some(head_id) = head
            .try_into_peeled_id()
            .map_err(|error| GitError::read(self.path(), error))?
        else {
            return Ok(None);
        };
        let hex = head_id.detach().to_hex().to_string();
        let len = hex_len.min(hex.len());
        Ok(Some(hex[..len].to_string()))
    }
}

#[cfg(test)]
mod tests {
    use fs_err as fs;
    use git2::Repository;
    use tempfile::tempdir;

    use super::GitRepository;

    fn init_repo(root: &std::path::Path) {
        fs::create_dir_all(root).expect("create repo");
        Repository::init(root).expect("init repo");
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
