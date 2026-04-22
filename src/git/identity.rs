use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};

use gix::discover::{
    path::from_plain_file as read_plain_git_path, repository::Path as GixRepositoryPath, upwards,
};

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
    upwards(&resolved)
        .ok()
        .and_then(|(repository, _trust)| identity_from_discovered_repository(repository))
        .or_else(|| infer_known_worktree_identity(&resolved))
}

fn identity_from_discovered_repository(
    repository: GixRepositoryPath,
) -> Option<GitCheckoutIdentity> {
    match repository {
        GixRepositoryPath::WorkTree(work_dir) => {
            let checkout_root = canonicalized(work_dir);
            Some(GitCheckoutIdentity {
                repository_root: checkout_root.clone(),
                checkout_root,
                kind: GitCheckoutKind::Repository,
            })
        }
        GixRepositoryPath::LinkedWorkTree { work_dir, git_dir } => {
            let checkout_root = canonicalized(work_dir);
            let repository_root = linked_worktree_repository_root(&git_dir)?;
            let kind = if repository_root == checkout_root {
                GitCheckoutKind::Repository
            } else {
                GitCheckoutKind::Worktree {
                    name: linked_worktree_name(&checkout_root, &git_dir),
                }
            };
            Some(GitCheckoutIdentity {
                repository_root,
                checkout_root,
                kind,
            })
        }
        GixRepositoryPath::Repository(repository_root) => {
            let repository_root = canonicalized(repository_root);
            Some(GitCheckoutIdentity {
                checkout_root: repository_root.clone(),
                repository_root,
                kind: GitCheckoutKind::Repository,
            })
        }
    }
}

fn linked_worktree_repository_root(git_dir: &Path) -> Option<PathBuf> {
    let common_dir = read_plain_git_path(&git_dir.join("commondir"))?.ok()?;
    let common_dir = if common_dir.is_absolute() {
        common_dir
    } else {
        git_dir.join(common_dir)
    };
    canonicalized(common_dir).parent().map(Path::to_path_buf)
}

fn linked_worktree_name(checkout_root: &Path, git_dir: &Path) -> String {
    checkout_root
        .file_name()
        .or_else(|| git_dir.file_name())
        .map_or_else(String::new, |name| name.to_string_lossy().to_string())
}

fn canonicalized(path: PathBuf) -> PathBuf {
    path.canonicalize().unwrap_or(path)
}

#[must_use]
pub fn infer_known_worktree_identity(path: &Path) -> Option<GitCheckoutIdentity> {
    let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let components: Vec<_> = resolved.components().collect();
    let marker_index = components.windows(3).position(is_known_worktree_marker)?;
    let worktree_name = component_text(components[marker_index + 2])?;
    let repository_root = build_path_from_components(&components[..marker_index]);
    let checkout_root = build_path_from_components(&components[..=marker_index + 2]);

    if repository_root.as_os_str().is_empty() || checkout_root.as_os_str().is_empty() {
        return None;
    }

    Some(GitCheckoutIdentity {
        repository_root,
        checkout_root,
        kind: GitCheckoutKind::Worktree {
            name: worktree_name,
        },
    })
}

fn is_known_worktree_marker(components: &[Component<'_>]) -> bool {
    components[0].as_os_str() == OsStr::new(".claude")
        && components[1].as_os_str() == OsStr::new("worktrees")
        && !components[2].as_os_str().is_empty()
}

fn component_text(component: Component<'_>) -> Option<String> {
    let text = component.as_os_str().to_string_lossy().trim().to_string();
    (!text.is_empty()).then_some(text)
}

fn build_path_from_components(components: &[Component<'_>]) -> PathBuf {
    let mut path = PathBuf::new();
    for component in components {
        path.push(component.as_os_str());
    }
    path
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

    use super::{
        GitCheckoutKind, canonical_checkout_root, infer_known_worktree_identity,
        resolve_git_checkout_identity,
    };
    use crate::git::mutation::create_linked_worktree;

    fn init_repo_with_commit(root: &std::path::Path) -> String {
        fs::create_dir_all(root).expect("create repo");
        fs::write(root.join("README.md"), "hello\n").expect("write readme");

        run_git(root, &["init"]);
        run_git(root, &["config", "user.email", "test@example.com"]);
        run_git(root, &["config", "user.name", "test"]);
        run_git(root, &["add", "README.md"]);
        run_git(
            root,
            &["-c", "commit.gpgsign=false", "commit", "-m", "init"],
        );

        run_git_output(root, &["rev-parse", "HEAD"])
    }

    fn run_git(dir: &std::path::Path, args: &[&str]) {
        let output = Command::new("git")
            .args(["-C"])
            .arg(dir)
            .args(args)
            .output()
            .expect("run git");
        assert!(output.status.success(), "git {:?} failed", args);
    }

    fn run_git_output(dir: &std::path::Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .args(["-C"])
            .arg(dir)
            .args(args)
            .output()
            .expect("run git");
        assert!(output.status.success(), "git {:?} failed", args);
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    #[test]
    fn resolve_git_checkout_identity_for_repo_subdirectory() {
        let tmp = tempdir().expect("tempdir");
        let repo_root = tmp.path().join("repo");
        let nested = repo_root.join("src/nested");
        init_repo_with_commit(&repo_root);
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
        let head_sha = init_repo_with_commit(&repo_root);
        fs::create_dir_all(&worktrees_root).expect("create worktrees root");

        create_linked_worktree(
            &repo_root,
            "feature-branch",
            &worktree,
            "feature-branch",
            &head_sha,
        )
        .expect("create worktree");

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
    fn infer_known_worktree_identity_uses_claude_worktree_layout_without_git() {
        let root = std::path::PathBuf::from("/repo");
        let worktree = root.join(".claude/worktrees/feature-branch");

        let identity = infer_known_worktree_identity(&worktree).expect("identity");

        assert_eq!(identity.repository_root, root);
        assert_eq!(identity.checkout_root, worktree);
        assert_eq!(
            identity.kind,
            GitCheckoutKind::Worktree {
                name: "feature-branch".to_string(),
            }
        );
    }

    #[test]
    fn resolve_git_checkout_identity_returns_none_for_non_git_path() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("plain");
        fs::create_dir_all(&path).expect("create plain path");

        assert!(resolve_git_checkout_identity(&path).is_none());
        assert_eq!(
            canonical_checkout_root(&path),
            path.canonicalize().expect("canonicalize plain path")
        );
    }
}
