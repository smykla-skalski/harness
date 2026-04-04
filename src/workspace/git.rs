use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitCheckoutKind {
    Repository,
    Worktree { name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitCheckoutIdentity {
    pub repository_root: PathBuf,
    pub checkout_root: PathBuf,
    pub kind: GitCheckoutKind,
}

impl GitCheckoutIdentity {
    #[must_use]
    pub fn is_worktree(&self) -> bool {
        matches!(self.kind, GitCheckoutKind::Worktree { .. })
    }

    #[must_use]
    pub fn worktree_name(&self) -> Option<&str> {
        match &self.kind {
            GitCheckoutKind::Repository => None,
            GitCheckoutKind::Worktree { name } => Some(name.as_str()),
        }
    }
}

#[must_use]
pub fn resolve_git_checkout_identity(path: &Path) -> Option<GitCheckoutIdentity> {
    let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let output = Command::new("git")
        .arg("-C")
        .arg(&resolved)
        .args([
            "rev-parse",
            "--path-format=absolute",
            "--show-toplevel",
            "--git-common-dir",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut lines = stdout.lines();
    let raw_checkout = PathBuf::from(lines.next()?);
    let git_common_dir = PathBuf::from(lines.next()?);
    let raw_repository = git_common_dir.parent()?.to_path_buf();
    let checkout_root = raw_checkout
        .canonicalize()
        .unwrap_or(raw_checkout);
    let repository_root = raw_repository
        .canonicalize()
        .unwrap_or(raw_repository);
    let kind = if checkout_root == repository_root {
        GitCheckoutKind::Repository
    } else {
        GitCheckoutKind::Worktree {
            name: checkout_root
                .file_name()
                .map_or_else(String::new, |name| name.to_string_lossy().to_string()),
        }
    };

    Some(GitCheckoutIdentity {
        repository_root,
        checkout_root,
        kind,
    })
}

#[must_use]
pub fn canonical_checkout_root(path: &Path) -> PathBuf {
    resolve_git_checkout_identity(path).map_or_else(
        || path.canonicalize().unwrap_or_else(|_| path.to_path_buf()),
        |identity| identity.checkout_root,
    )
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    use fs_err as fs;
    use tempfile::tempdir;

    use super::{GitCheckoutKind, canonical_checkout_root, resolve_git_checkout_identity};

    fn git(path: &std::path::Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(path)
            .args(args)
            .status()
            .expect("run git");
        assert!(status.success(), "git {:?} failed", args);
    }

    fn init_repo(root: &std::path::Path) {
        fs::create_dir_all(root).expect("create repo");
        git(root, &["init"]);
        git(root, &["config", "user.name", "Harness Tests"]);
        git(root, &["config", "user.email", "harness@example.com"]);
        fs::write(root.join("README.md"), "hello\n").expect("write readme");
        git(root, &["add", "README.md"]);
        git(root, &["commit", "-m", "init"]);
    }

    #[test]
    fn resolve_git_checkout_identity_for_repo_subdirectory() {
        let tmp = tempdir().expect("tempdir");
        let repo_root = tmp.path().join("repo");
        let nested = repo_root.join("src/nested");
        init_repo(&repo_root);
        fs::create_dir_all(&nested).expect("create nested");

        let identity = resolve_git_checkout_identity(&nested).expect("identity");
        let expected = repo_root.canonicalize().expect("canonicalize");

        assert_eq!(identity.repository_root, expected);
        assert_eq!(identity.checkout_root, expected);
        assert_eq!(identity.kind, GitCheckoutKind::Repository);
        assert_eq!(canonical_checkout_root(&nested), expected);
    }

    #[test]
    fn resolve_git_checkout_identity_for_worktree() {
        let tmp = tempdir().expect("tempdir");
        let repo_root = tmp.path().join("repo");
        let worktrees_root = repo_root.join(".claude/worktrees");
        let worktree = worktrees_root.join("feature-branch");
        init_repo(&repo_root);
        fs::create_dir_all(&worktrees_root).expect("create worktrees root");
        git(
            &repo_root,
            &[
                "worktree",
                "add",
                worktree.to_str().expect("utf8"),
                "-b",
                "feature-branch",
            ],
        );

        let identity = resolve_git_checkout_identity(&worktree).expect("identity");
        let expected_repo = repo_root.canonicalize().expect("canonicalize repo");
        let expected_worktree = worktree.canonicalize().expect("canonicalize worktree");

        assert_eq!(identity.repository_root, expected_repo);
        assert_eq!(identity.checkout_root, expected_worktree);
        assert_eq!(
            identity.kind,
            GitCheckoutKind::Worktree {
                name: "feature-branch".to_string(),
            }
        );
        assert_eq!(canonical_checkout_root(&worktree), expected_worktree);
    }

    #[test]
    fn resolve_git_checkout_identity_returns_none_for_non_git_path() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("plain-dir");
        fs::create_dir_all(&path).expect("create plain dir");

        assert!(resolve_git_checkout_identity(&path).is_none());
        assert_eq!(canonical_checkout_root(&path), path.canonicalize().expect("canonicalize"));
    }
}
