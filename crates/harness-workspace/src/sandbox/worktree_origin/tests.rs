use std::fs;
use std::path::Path;

use tempfile::TempDir;

use super::hold_worktree_origin_grant;

/// Builds `<root>/<session>/workspace` and returns (origin, worktree).
fn session_worktree(root: &Path, origin: Option<&Path>) -> std::path::PathBuf {
    let session_root = root.join("11111111-2222-3333-4444-555555555555");
    let worktree = session_root.join("workspace");
    fs::create_dir_all(&worktree).expect("create worktree");
    if let Some(origin) = origin {
        fs::write(
            session_root.join(".origin"),
            origin.to_string_lossy().as_bytes(),
        )
        .expect("write origin marker");
    }
    worktree
}

#[test]
fn a_session_worktree_grants_its_origin_checkout() {
    let temp = TempDir::new().expect("temp dir");
    let origin = temp.path().join("checkout");
    fs::create_dir_all(&origin).expect("create origin");
    let worktree = session_worktree(temp.path(), Some(&origin));

    let grant = hold_worktree_origin_grant(&worktree);

    assert_eq!(
        grant.origin(),
        Some(origin.canonicalize().expect("canonicalize origin").as_path()),
        "a linked worktree must grant the origin that holds its gitdir"
    );
}

#[test]
fn a_worktree_without_an_origin_marker_grants_nothing() {
    let temp = TempDir::new().expect("temp dir");
    let worktree = session_worktree(temp.path(), None);

    assert_eq!(hold_worktree_origin_grant(&worktree).origin(), None);
}

#[test]
fn a_dangling_origin_marker_grants_nothing() {
    let temp = TempDir::new().expect("temp dir");
    let missing = temp.path().join("moved-away");
    let worktree = session_worktree(temp.path(), Some(&missing));

    assert_eq!(
        hold_worktree_origin_grant(&worktree).origin(),
        None,
        "an origin that moved must not turn a readable worktree into an error"
    );
}
