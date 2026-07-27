use std::fs;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::hold_worktree_origin_grant;
use crate::workspace::layout::SessionLayout;

/// Lays out a real session on disk so the grant is proven against
/// `SessionLayout`, not against hardcoded directory names.
fn session_worktree(sessions_root: &Path, origin: Option<&Path>) -> PathBuf {
    let layout = SessionLayout {
        sessions_root: sessions_root.to_path_buf(),
        project_name: "checkout".to_string(),
        session_id: "11111111-2222-3333-4444-555555555555".to_string(),
    };
    let worktree = layout.workspace();
    fs::create_dir_all(&worktree).expect("create worktree");
    if let Some(origin) = origin {
        fs::write(layout.origin_marker(), origin.to_string_lossy().as_bytes())
            .expect("write origin marker");
    }
    worktree
}

#[test]
fn a_session_worktree_grants_its_origin_checkout() {
    let temp = TempDir::new().expect("temp dir");
    let origin = temp.path().join("origin");
    fs::create_dir_all(&origin).expect("create origin");
    let worktree = session_worktree(&temp.path().join("sessions"), Some(&origin));

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
    let worktree = session_worktree(&temp.path().join("sessions"), None);

    assert_eq!(hold_worktree_origin_grant(&worktree).origin(), None);
}

#[test]
fn a_dangling_origin_marker_grants_nothing() {
    let temp = TempDir::new().expect("temp dir");
    let missing = temp.path().join("moved-away");
    let worktree = session_worktree(&temp.path().join("sessions"), Some(&missing));

    assert_eq!(
        hold_worktree_origin_grant(&worktree).origin(),
        None,
        "an origin that moved must not turn a readable worktree into an error"
    );
}
