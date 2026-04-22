use std::process::Command;

use harness_testkit::{git_branches_matching, git_head_sha, init_git_repo_with_seed};
use tempfile::TempDir;

use super::*;
use crate::workspace::layout::SessionLayout;

fn init_origin_repo(tmp: &std::path::Path) {
    init_git_repo_with_seed(tmp);
}

fn commit_file(dir: &std::path::Path, path: &str, contents: &[u8], message: &str) {
    std::fs::write(dir.join(path), contents).unwrap();
    run_git(dir, &["add", path]);
    run_git(
        dir,
        &["-c", "commit.gpgsign=false", "commit", "-m", message],
    );
}

fn run_git(dir: &std::path::Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
}

fn init_checkout_with_upstream_remote() -> TempDir {
    let upstream = TempDir::new().unwrap();

    Command::new("git")
        .args(["init", "--bare"])
        .arg(upstream.path())
        .output()
        .expect("init bare remote");

    let seed = TempDir::new().unwrap();
    init_origin_repo(seed.path());

    let repo = gix::open(seed.path()).expect("open seed repo");
    let default_branch = repo
        .head_name()
        .expect("head name")
        .expect("head is branch")
        .shorten()
        .to_string();

    Command::new("git")
        .args(["-C"])
        .arg(seed.path())
        .args(["remote", "add", "upstream"])
        .arg(upstream.path())
        .output()
        .expect("add upstream remote");

    let refspec = format!("refs/heads/{default_branch}:refs/heads/main");
    Command::new("git")
        .args(["-C"])
        .arg(seed.path())
        .args(["push", "upstream", &refspec])
        .output()
        .expect("push seed");

    Command::new("git")
        .args(["-C"])
        .arg(upstream.path())
        .args(["symbolic-ref", "HEAD", "refs/heads/main"])
        .output()
        .expect("set upstream HEAD");

    let checkout = TempDir::new().unwrap();

    Command::new("git")
        .args(["clone", "--origin", "upstream"])
        .arg(upstream.path())
        .arg(checkout.path())
        .output()
        .expect("clone checkout from upstream");

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
    assert!(layout.workspace().join("README.md").exists());
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
    assert!(git_branches_matching(origin.path(), "harness/").is_empty());
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

    assert!(
        git_branches_matching(origin.path(), "harness/").is_empty(),
        "harness branch should have been deleted by rollback"
    );
}

#[test]
fn resolve_base_ref_prefers_tracking_remote_head_over_local_head() {
    let checkout = init_checkout_with_upstream_remote();
    let remote_tip = git_head_sha(checkout.path(), "upstream/main");

    commit_file(
        checkout.path(),
        "LOCAL",
        b"local-only",
        "local-only diverges from upstream/main",
    );
    let local_tip = git_head_sha(checkout.path(), "HEAD");
    assert_ne!(
        local_tip, remote_tip,
        "test setup must diverge from upstream"
    );

    let repository = crate::git::GitRepository::discover(checkout.path()).expect("discover repo");
    let resolved = resolve_base_ref(&repository).expect("resolve base ref");
    assert_eq!(resolved, "upstream/main");
}
