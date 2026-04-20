use tempfile::TempDir;
use tokio::process::Command;

use super::*;
use crate::workspace::layout::SessionLayout;

async fn init_origin_repo(tmp: &std::path::Path) {
    Command::new("git").arg("init").arg("-q").arg(tmp)
        .output().await.unwrap();
    std::fs::write(tmp.join("README"), b"seed").unwrap();
    Command::new("git").current_dir(tmp)
        .args(["add", "."]).output().await.unwrap();
    Command::new("git").current_dir(tmp)
        .args(["-c", "user.email=a@b", "-c", "user.name=a",
               "commit", "-q", "-m", "seed"]).output().await.unwrap();
}

#[tokio::test]
async fn creates_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path()).await;
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "abc12345".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).await.expect("create");
    assert!(layout.workspace().join("README").exists());
    assert!(layout.memory().exists());
}

#[tokio::test]
async fn destroy_removes_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path()).await;
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "ab234567".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).await.unwrap();
    WorktreeController::destroy(origin.path(), &layout).await.expect("destroy");
    assert!(!layout.workspace().exists());
    let branches = Command::new("git").current_dir(origin.path())
        .args(["branch", "--list", "harness/*"])
        .output().await.unwrap();
    assert!(std::str::from_utf8(&branches.stdout).unwrap().trim().is_empty());
}
