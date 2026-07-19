use std::process::Command;

use tempfile::tempdir;

use super::*;
use crate::task_board::TaskBoardOrchestratorSettings;

fn run_git(path: &std::path::Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[tokio::test]
async fn unconfigured_publication_is_rejected_before_write_launch() {
    let temp = tempdir().expect("tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("worktree directory");
    run_git(&worktree, &["init"]);
    run_git(&worktree, &["config", "user.name", "Test User"]);
    run_git(&worktree, &["config", "user.email", "test@example.com"]);
    std::fs::write(worktree.join("README.md"), "fixture\n").expect("fixture file");
    run_git(&worktree, &["add", "README.md"]);
    run_git(
        &worktree,
        &["-c", "commit.gpgsign=false", "commit", "-m", "fixture"],
    );

    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("database");
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
        .await
        .expect("default settings");
    let mut item = TaskBoardItem::new(
        "write-unpublishable".into(),
        "Write workflow".into(),
        "Acceptance criteria".into(),
        "2026-07-18T10:00:00Z".into(),
    );
    item.execution_repository = Some("example/compass".into());
    item.planning.summary = Some("Implement safely".into());
    item.planning.approved_by = Some("operator".into());
    item.planning.approved_at = Some("2026-07-18T10:05:00Z".into());
    let mutation = db.create_task_board_item(item).await.expect("create item");

    let error = prepare_write_workflow_launch(
        &db,
        "write-unpublishable",
        "session-1",
        "task-1",
        "execution-1",
        worktree.to_string_lossy().as_ref(),
        Some(mutation.item_revision),
    )
    .await
    .expect_err("unpublishable workflow must not launch workers");

    assert!(
        error
            .to_string()
            .contains("requires configured GitHub automation")
    );
}
