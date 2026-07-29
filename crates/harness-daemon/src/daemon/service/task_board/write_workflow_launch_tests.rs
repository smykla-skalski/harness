use std::process::Command;

use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::*;
use crate::daemon::service::sync_task_board_github_tokens;
use crate::task_board::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardOrchestratorSettings, TaskBoardPullRequestHeadIdentity,
    TaskBoardWorkflowKind,
};

fn dependency_item() -> TaskBoardItem {
    let mut item = approved_item("dep-item", Some("acme/widgets"));
    item.workflow_kind = TaskBoardWorkflowKind::PrFix;
    item
}

fn frozen_identity(revision: &str) -> TaskBoardPullRequestIdentity {
    TaskBoardPullRequestIdentity {
        repository: "acme/widgets".into(),
        number: 17,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: "acme/widgets".into(),
            branch: "renovate/dependency-update".into(),
            revision: revision.into(),
        }),
    }
}

/// The frozen pull request head, not the session worktree HEAD, is the dependency base. The
/// worktree starts on the default branch, so demanding they match rejected every real launch.
#[test]
fn dependency_identity_freezes_the_pull_request_head_over_the_worktree() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let item = dependency_item();
        let (pull_request, base_head_revision) =
            resolve_write_identity(&item, "/nonexistent/worktree", Some(frozen_identity("cafef00d")))
                .await
                .expect("dependency identity resolves without a worktree checkout");

        assert_eq!(base_head_revision, "cafef00d");
        assert_eq!(
            pull_request.and_then(|identity| identity.head).map(|head| head.revision),
            Some("cafef00d".to_string())
        );
    });
}

#[test]
fn dependency_identity_requires_a_frozen_head() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let item = dependency_item();
        let mut identity = frozen_identity("cafef00d");
        identity.head = None;

        let error = resolve_write_identity(&item, "/nonexistent/worktree", Some(identity))
            .await
            .expect_err("a dependency launch without a frozen head must fail");

        assert!(
            error.to_string().contains("no frozen pull request head"),
            "unexpected error: {error}"
        );
    });
}

#[test]
fn stale_pull_request_head_stops_before_agent_work() {
    let error = stop_on_stale_pull_request_head(
        Some(&frozen_identity("deadbeef")),
        Some(&frozen_identity("cafef00d")),
    )
    .expect_err("a changed head must stop the launch");

    let message = error.to_string();
    assert!(
        message.contains("stale head") && message.contains("cafef00d") && message.contains("deadbeef"),
        "stale head reason must name both revisions: {message}"
    );
}

#[test]
fn a_changed_pull_request_number_reports_an_identity_change_not_a_stale_head() {
    let mut fresh = frozen_identity("cafef00d");
    fresh.number = 18;

    let error = stop_on_stale_pull_request_head(Some(&fresh), Some(&frozen_identity("cafef00d")))
        .expect_err("a changed pull request number must stop the launch");

    let message = error.to_string();
    assert!(
        message.contains("identity changed") && !message.contains("stale head"),
        "a changed number must not be reported as a stale head: {message}"
    );
}

#[test]
fn unchanged_pull_request_head_is_not_stale() {
    stop_on_stale_pull_request_head(
        Some(&frozen_identity("cafef00d")),
        Some(&frozen_identity("cafef00d")),
    )
    .expect("an unchanged head must not be reported stale");
}

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
