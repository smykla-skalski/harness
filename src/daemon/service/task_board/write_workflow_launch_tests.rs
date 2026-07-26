use std::process::Command;

use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::*;
use crate::daemon::service::sync_task_board_github_tokens;
use crate::task_board::{TaskBoardGitHubTokensSyncRequest, TaskBoardOrchestratorSettings};

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

fn init_worktree(root: &std::path::Path) -> std::path::PathBuf {
    let worktree = root.join("worktree");
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
    worktree
}

fn approved_item(id: &str, repository: Option<&str>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Write workflow".into(),
        "Acceptance criteria".into(),
        "2026-07-18T10:00:00Z".into(),
    );
    item.execution_repository = repository.map(Into::into);
    item.planning.summary = Some("Implement safely".into());
    item.planning.approved_by = Some("operator".into());
    item.planning.approved_at = Some("2026-07-18T10:05:00Z".into());
    item
}

fn seed_global_token() {
    sync_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
        global_token: Some("github-token".into()),
        repository_tokens: Vec::new(),
    })
    .expect("seed global token");
}

/// The regression this whole surface exists for: a board fed from many
/// repositories must launch every one of them, not just whichever slug happened
/// to be typed into settings.
#[test]
fn write_launch_targets_each_item_own_repository() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let worktree = init_worktree(temp.path());
            let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
                .await
                .expect("database");
            db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
                .await
                .expect("default settings");
            seed_global_token();

            let repositories = ["example/compass", "another-owner/atlas"];
            for (index, repository) in repositories.iter().enumerate() {
                let id = format!("write-item-{index}");
                let mutation = db
                    .create_task_board_item(approved_item(&id, Some(repository)))
                    .await
                    .expect("create item");
                let launch = prepare_write_workflow_launch(
                    &db,
                    &id,
                    &format!("session-{index}"),
                    &format!("task-{index}"),
                    &format!("execution-{index}"),
                    worktree.to_string_lossy().as_ref(),
                    Some(mutation.item_revision),
                )
                .await
                .expect("every item repository must launch")
                .expect("write workflow launch");

                assert_eq!(launch.execution_repository.as_deref(), Some(*repository));
            }
        });
    });
}

#[test]
fn write_launch_without_a_repository_is_rejected() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let worktree = init_worktree(temp.path());
            let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
                .await
                .expect("database");
            db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
                .await
                .expect("default settings");
            seed_global_token();

            let mutation = db
                .create_task_board_item(approved_item("write-unlinked", None))
                .await
                .expect("create item");

            let error = prepare_write_workflow_launch(
                &db,
                "write-unlinked",
                "session-1",
                "task-1",
                "execution-1",
                worktree.to_string_lossy().as_ref(),
                Some(mutation.item_revision),
            )
            .await
            .expect_err("an item with no repository must not launch workers");

            assert!(
                error.to_string().contains("no target repository"),
                "unexpected error: {error}"
            );
        });
    });
}

#[test]
fn write_launch_without_a_repository_token_is_rejected() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let worktree = init_worktree(temp.path());
            let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
                .await
                .expect("database");
            db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
                .await
                .expect("default settings");
            sync_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest::default())
                .expect("clear tokens");

            let mutation = db
                .create_task_board_item(approved_item("write-untokened", Some("example/compass")))
                .await
                .expect("create item");

            let error = prepare_write_workflow_launch(
                &db,
                "write-untokened",
                "session-1",
                "task-1",
                "execution-1",
                worktree.to_string_lossy().as_ref(),
                Some(mutation.item_revision),
            )
            .await
            .expect_err("a repository without a token must not launch workers");

            assert!(
                error
                    .to_string()
                    .contains("no GitHub token for 'example/compass'"),
                "unexpected error: {error}"
            );
        });
    });
}
