use std::process::Command;

use tempfile::TempDir;

use super::*;
use crate::workspace::layout::SessionLayout;

fn init_origin_repo(tmp: &std::path::Path) {
    Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(tmp)
        .output()
        .unwrap();
    std::fs::write(tmp.join("README"), b"seed").unwrap();
    Command::new("git")
        .current_dir(tmp)
        .args(["add", "."])
        .output()
        .unwrap();
    Command::new("git")
        .current_dir(tmp)
        .args([
            "-c",
            "user.email=a@b",
            "-c",
            "user.name=a",
            "commit",
            "-q",
            "-m",
            "seed",
        ])
        .output()
        .unwrap();
}

fn git_output(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .current_dir(dir)
        .args(args)
        .output()
        .unwrap()
}

fn git_sha(dir: &std::path::Path, reference: &str) -> String {
    let output = git_output(dir, &["rev-parse", reference]);
    assert!(output.status.success(), "git rev-parse failed for {reference}");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn commit_file(dir: &std::path::Path, path: &str, contents: &[u8], message: &str) {
    std::fs::write(dir.join(path), contents).unwrap();
    git_output(dir, &["add", path]);
    let commit = git_output(
        dir,
        &[
            "-c",
            "user.email=a@b",
            "-c",
            "user.name=a",
            "commit",
            "-q",
            "-m",
            message,
        ],
    );
    assert!(commit.status.success(), "git commit failed: {message}");
}

fn init_checkout_with_upstream_remote() -> TempDir {
    let upstream = TempDir::new().unwrap();
    let init_remote = Command::new("git")
        .args(["init", "--bare", "-q"])
        .arg(upstream.path())
        .output()
        .unwrap();
    assert!(init_remote.status.success(), "init bare remote");

    let seed = TempDir::new().unwrap();
    init_origin_repo(seed.path());
    let add_remote = Command::new("git")
        .current_dir(seed.path())
        .args(["remote", "add", "upstream"])
        .arg(upstream.path())
        .output()
        .unwrap();
    assert!(add_remote.status.success(), "add upstream remote");
    let push = Command::new("git")
        .current_dir(seed.path())
        .args(["push", "-u", "upstream", "HEAD:refs/heads/main"])
        .output()
        .unwrap();
    assert!(push.status.success(), "push seed to upstream");
    let set_head = Command::new("git")
        .current_dir(upstream.path())
        .args(["symbolic-ref", "HEAD", "refs/heads/main"])
        .output()
        .unwrap();
    assert!(set_head.status.success(), "set upstream HEAD");

    let checkout = TempDir::new().unwrap();
    let clone = Command::new("git")
        .args(["clone", "--origin", "upstream"])
        .arg(upstream.path())
        .arg(checkout.path())
        .output()
        .unwrap();
    assert!(clone.status.success(), "clone checkout from upstream");
    checkout
}

#[test]
fn creates_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "abc12345".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).expect("create");
    assert!(layout.workspace().join("README").exists());
    assert!(layout.memory().exists());
}

#[test]
fn destroy_removes_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "ab234567".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).unwrap();
    WorktreeController::destroy(origin.path(), &layout).expect("destroy");
    assert!(!layout.workspace().exists());
    let branches = Command::new("git")
        .current_dir(origin.path())
        .args(["branch", "--list", "harness/*"])
        .output()
        .unwrap();
    assert!(
        std::str::from_utf8(&branches.stdout)
            .unwrap()
            .trim()
            .is_empty()
    );
}

/// Verify that when a post-add filesystem step fails, `create` rolls back
/// the worktree and branch so no orphans are left in the origin repo.
///
/// Injection: pre-create a regular file at `layout.memory()` so that
/// `fs::create_dir_all(memory())` fails with ENOTDIR, triggering rollback.
#[test]
fn rollback_on_memory_create_failure() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "cd345678".into(),
    };
    std::fs::create_dir_all(layout.session_root()).unwrap();
    std::fs::write(layout.memory(), b"blocker").unwrap();

    let result = WorktreeController::create(origin.path(), &layout, None);
    assert!(
        result.is_err(),
        "expected create to fail due to blocked memory dir"
    );

    assert!(
        !layout.workspace().exists(),
        "workspace should have been removed by rollback"
    );

    let branches = Command::new("git")
        .current_dir(origin.path())
        .args(["branch", "--list", "harness/*"])
        .output()
        .unwrap();
    assert!(
        std::str::from_utf8(&branches.stdout)
            .unwrap()
            .trim()
            .is_empty(),
        "harness branch should have been deleted by rollback"
    );
}

#[test]
fn resolve_base_ref_prefers_tracking_remote_head_over_local_head() {
    let checkout = init_checkout_with_upstream_remote();
    let remote_tip = git_sha(checkout.path(), "upstream/main");

    commit_file(
        checkout.path(),
        "LOCAL",
        b"local-only",
        "local-only diverges from upstream/main",
    );
    let local_tip = git_sha(checkout.path(), "HEAD");
    assert_ne!(local_tip, remote_tip, "test setup must diverge from upstream");

    let resolved = resolve_base_ref(checkout.path()).expect("resolve base ref");
    assert_eq!(resolved, "upstream/main");
}
