use std::env;
use std::process::Command;
use std::thread;

use harness_testkit::with_isolated_harness_env;
use regex::Regex;
use tempfile::tempdir;
use tokio::runtime::Builder as RuntimeBuilder;

use super::*;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::daemon::service::sync_task_board_github_tokens;
use crate::task_board::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardOrchestratorSettings,
    TaskBoardPullRequestHeadIdentity, TaskBoardWorkflowKind,
};

const WRITE_LAUNCH_STACK_CHILD_ENV: &str = "HARNESS_TEST_WRITE_LAUNCH_STACK_CHILD";
const WRITE_LAUNCH_STACK_TEST: &str = "daemon::service::task_board::write_workflow_launch::tests::write_publication_validation_runs_on_fresh_task_stack";
const CONSTRAINED_WRITE_LAUNCH_STACK: usize = 128 * 1024;

#[test]
fn write_publication_validation_runs_on_fresh_task_stack() {
    if env::var_os(WRITE_LAUNCH_STACK_CHILD_ENV).is_none() {
        let inline = run_write_launch_stack_child("inline");
        assert!(
            !inline.status.success()
                && String::from_utf8_lossy(&inline.stderr).contains("stack overflow"),
            "inline validation did not reproduce the stack overflow: stdout={} stderr={}",
            String::from_utf8_lossy(&inline.stdout),
            String::from_utf8_lossy(&inline.stderr),
        );
        let isolated = run_write_launch_stack_child("isolated");
        assert!(
            isolated.status.success(),
            "isolated validation failed: stdout={} stderr={}",
            String::from_utf8_lossy(&isolated.stdout),
            String::from_utf8_lossy(&isolated.stderr),
        );
        return;
    }

    let mode = env::var(WRITE_LAUNCH_STACK_CHILD_ENV).expect("write launch stack child mode");
    let worker = thread::Builder::new()
        .name("constrained-write-launch".into())
        .stack_size(CONSTRAINED_WRITE_LAUNCH_STACK)
        .spawn(move || {
            if mode == "inline" {
                return compile_pull_request_tracking_regex();
            }
            let runtime = RuntimeBuilder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
                .expect("write launch runtime");
            runtime.block_on(run_write_launch_task(async {
                compile_pull_request_tracking_regex()
            }))
        })
        .expect("spawn constrained write launch");
    worker
        .join()
        .expect("constrained write launch thread")
        .expect("pull request validation");
}

fn compile_pull_request_tracking_regex() -> Result<(), CliError> {
    Regex::new(r"(?i)part of\s+(?:([\w.-]+/[\w.-]+))?#(\d+)")
        .map(|_| ())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("compile pull request tracking regex: {error}"))
                .into()
        })
}

fn run_write_launch_stack_child(mode: &str) -> std::process::Output {
    Command::new(env::current_exe().expect("current test executable"))
        .args(["--exact", WRITE_LAUNCH_STACK_TEST, "--nocapture"])
        .env(WRITE_LAUNCH_STACK_CHILD_ENV, mode)
        .output()
        .expect("run isolated write launch stack test")
}

fn dependency_item() -> TaskBoardItem {
    let mut item = approved_item("dep-item", Some("acme/widgets"));
    item.workflow_kind = TaskBoardWorkflowKind::PrFix;
    item.workflow.pr_head_revision = Some("cafef00d".into());
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

#[test]
fn dependency_identity_requires_the_worktree_at_the_frozen_pull_request_head() {
    let temp = tempdir().expect("tempdir");
    let worktree = init_worktree(temp.path());
    let head = git_output(&worktree, &["rev-parse", "HEAD"]);
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let item = dependency_item();
        let (pull_request, base_head_revision) = resolve_write_identity(
            &item,
            worktree.to_string_lossy().as_ref(),
            Some(frozen_identity(&head)),
        )
        .await
        .expect("dependency identity resolves at its frozen checkout");

        assert_eq!(base_head_revision, head);
        assert_eq!(
            pull_request
                .and_then(|identity| identity.head)
                .map(|head| head.revision),
            Some(head)
        );
    });
}

#[test]
fn dependency_identity_rejects_a_worktree_on_another_head() {
    let temp = tempdir().expect("tempdir");
    let worktree = init_worktree(temp.path());
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let error = resolve_write_identity(
            &dependency_item(),
            worktree.to_string_lossy().as_ref(),
            Some(frozen_identity("0123456789abcdef0123456789abcdef01234567")),
        )
        .await
        .expect_err("a mismatched dependency checkout must fail");

        assert!(
            error
                .to_string()
                .contains("does not match frozen pull request head")
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
fn dependency_pin_uses_the_head_recorded_on_the_item() {
    let item = dependency_item();

    assert_eq!(
        frozen_dependency_revision(&item).expect("recorded dependency head"),
        Some("cafef00d")
    );
}

#[test]
fn dependency_pin_rejects_an_item_without_a_recorded_head() {
    let mut item = dependency_item();
    item.workflow.pr_head_revision = None;

    let error = frozen_dependency_revision(&item)
        .expect_err("dependency pinning must fail closed without the recorded head");

    assert!(
        error.to_string().contains("no recorded pull request head"),
        "unexpected error: {error}"
    );
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
        message.contains("stale head")
            && message.contains("cafef00d")
            && message.contains("deadbeef"),
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

fn git_output(path: &std::path::Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .expect("run git");
    assert!(output.status.success(), "git {args:?}");
    String::from_utf8(output.stdout)
        .expect("git output")
        .trim()
        .to_string()
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
