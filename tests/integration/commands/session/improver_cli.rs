//! CLI → service integration coverage for `session improver apply`.
//! Proves that the transport layer:
//!   * enforces `SessionAction::ImproverApply` against the session state,
//!   * resolves the session's real project directory (so a bogus
//!     `--project-dir` is ignored), and
//!   * denies actors lacking the improver permission (Worker, Observer).

use std::fs;

use clap::Parser;
use harness::app::cli::Cli;
use harness::session::service;

use super::with_session_test_env;
use crate::integration::helpers::run_command;

fn run_cli(args: &[&str]) -> i32 {
    let cli = Cli::try_parse_from(args).expect("parse cli");
    run_command(cli.command).expect("run cli")
}

fn bootstrap_improver_session(session_id: &str, project: &std::path::Path) -> (String, String) {
    let _state =
        service::start_session_with_policy("", "improver cli", project, Some(session_id), None)
            .unwrap();
    let _leader = service::join_session(
        session_id,
        harness::session::types::SessionRole::Leader,
        "claude",
        &[],
        Some("leader-persona"),
        project,
        None,
    )
    .unwrap();
    let improver_joined =
        temp_env::with_var("CODEX_SESSION_ID", Some("improver-cli-improver"), || {
            service::join_session(
                session_id,
                harness::session::types::SessionRole::Improver,
                "codex",
                &[],
                Some("improver-persona"),
                project,
                None,
            )
            .unwrap()
        });
    let improver_id = improver_joined
        .agents
        .keys()
        .find(|id| id.starts_with("codex-"))
        .expect("improver id present")
        .clone();
    let worker_joined = temp_env::with_var("CODEX_SESSION_ID", Some("improver-cli-worker"), || {
        service::join_session(
            session_id,
            harness::session::types::SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .unwrap()
    });
    let worker_id = worker_joined
        .agents
        .keys()
        .find(|id| id.starts_with("codex-") && *id != &improver_id)
        .expect("worker id present")
        .clone();
    (improver_id, worker_id)
}

#[test]
fn improver_apply_via_cli_allows_improver_and_uses_session_project_dir() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-improver", || {
        let project = tmp.path().join("project");
        fs::create_dir_all(project.join("agents/skills/demo")).unwrap();
        fs::write(project.join("agents/skills/demo/SKILL.md"), "old\n").unwrap();
        let contents_file = tmp.path().join("new-contents.md");
        fs::write(&contents_file, "new\n").unwrap();

        let (improver_id, _worker_id) = bootstrap_improver_session("rev-cli-6", &project);

        // Pass a bogus --project-dir to prove it cannot escape the session's
        // real project directory. The write must land in `project/`, not in
        // the bogus dir.
        let bogus = tempfile::tempdir().unwrap();
        let bogus_str = bogus.path().to_string_lossy().to_string();
        let contents_str = contents_file.to_string_lossy().to_string();
        let exit = run_cli(&[
            "harness",
            "session",
            "improver",
            "apply",
            "rev-cli-6",
            "--actor",
            &improver_id,
            "--issue-id",
            "python_traceback_output/abc",
            "--target",
            "skill",
            "--rel-path",
            "demo/SKILL.md",
            "--new-contents-file",
            &contents_str,
            "--project-dir",
            &bogus_str,
        ]);
        assert_eq!(exit, 0);

        let on_disk = fs::read_to_string(project.join("agents/skills/demo/SKILL.md")).unwrap();
        assert_eq!(on_disk, "new\n");
        assert!(
            !bogus.path().join("agents/skills/demo/SKILL.md").exists(),
            "bogus --project-dir must not receive the write"
        );
    });
}

#[test]
fn improver_apply_via_cli_denies_worker_actor() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-improver-deny-worker", || {
        let project = tmp.path().join("project");
        fs::create_dir_all(project.join("agents/skills/demo")).unwrap();
        fs::write(project.join("agents/skills/demo/SKILL.md"), "old\n").unwrap();
        let contents_file = tmp.path().join("new-contents.md");
        fs::write(&contents_file, "new\n").unwrap();

        let (_improver_id, worker_id) = bootstrap_improver_session("rev-cli-6-worker", &project);

        let project_str = project.to_string_lossy().to_string();
        let contents_str = contents_file.to_string_lossy().to_string();
        let cli = Cli::try_parse_from([
            "harness",
            "session",
            "improver",
            "apply",
            "rev-cli-6-worker",
            "--actor",
            &worker_id,
            "--issue-id",
            "x/y",
            "--target",
            "skill",
            "--rel-path",
            "demo/SKILL.md",
            "--new-contents-file",
            &contents_str,
            "--project-dir",
            &project_str,
        ])
        .expect("parse cli");
        let err = run_command(cli.command).expect_err("worker must be denied");
        assert!(
            err.to_string().to_lowercase().contains("permission")
                || err.to_string().to_lowercase().contains("cannot"),
            "expected permission-denied error, got: {err}"
        );
        assert_eq!(
            fs::read_to_string(project.join("agents/skills/demo/SKILL.md")).unwrap(),
            "old\n",
            "denied run must not mutate disk"
        );
    });
}

#[test]
fn improver_apply_via_cli_denies_observer_actor() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-improver-deny-observer", || {
        let project = tmp.path().join("project");
        fs::create_dir_all(project.join("agents/skills/demo")).unwrap();
        fs::write(project.join("agents/skills/demo/SKILL.md"), "old\n").unwrap();
        let contents_file = tmp.path().join("new-contents.md");
        fs::write(&contents_file, "new\n").unwrap();

        let _state = service::start_session_with_policy(
            "",
            "observer attempt",
            &project,
            Some("rev-cli-6-observer"),
            None,
        )
        .unwrap();
        let _leader = service::join_session(
            "rev-cli-6-observer",
            harness::session::types::SessionRole::Leader,
            "claude",
            &[],
            None,
            &project,
            None,
        )
        .unwrap();
        let observer_joined =
            temp_env::with_var("CODEX_SESSION_ID", Some("improver-cli-observer"), || {
                service::join_session(
                    "rev-cli-6-observer",
                    harness::session::types::SessionRole::Observer,
                    "codex",
                    &[],
                    None,
                    &project,
                    None,
                )
                .unwrap()
            });
        let observer_id = observer_joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("observer id")
            .clone();

        let project_str = project.to_string_lossy().to_string();
        let contents_str = contents_file.to_string_lossy().to_string();
        let cli = Cli::try_parse_from([
            "harness",
            "session",
            "improver",
            "apply",
            "rev-cli-6-observer",
            "--actor",
            &observer_id,
            "--issue-id",
            "z/w",
            "--target",
            "skill",
            "--rel-path",
            "demo/SKILL.md",
            "--new-contents-file",
            &contents_str,
            "--project-dir",
            &project_str,
        ])
        .expect("parse cli");
        let err = run_command(cli.command).expect_err("observer must be denied");
        assert!(
            err.to_string().to_lowercase().contains("permission")
                || err.to_string().to_lowercase().contains("cannot"),
            "expected permission-denied error, got: {err}"
        );
    });
}

#[test]
fn improver_apply_dry_run_as_improver_leaves_file_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-improver-dry", || {
        let project = tmp.path().join("project");
        fs::create_dir_all(project.join("agents/skills/demo")).unwrap();
        let target = project.join("agents/skills/demo/SKILL.md");
        fs::write(&target, "pristine\n").unwrap();
        let contents_file = tmp.path().join("new.md");
        fs::write(&contents_file, "would-write\n").unwrap();

        let (improver_id, _worker_id) = bootstrap_improver_session("rev-cli-7", &project);

        let project_str = project.to_string_lossy().to_string();
        let contents_str = contents_file.to_string_lossy().to_string();
        let exit = run_cli(&[
            "harness",
            "session",
            "improver",
            "apply",
            "rev-cli-7",
            "--actor",
            &improver_id,
            "--issue-id",
            "x/y",
            "--target",
            "skill",
            "--rel-path",
            "demo/SKILL.md",
            "--new-contents-file",
            &contents_str,
            "--dry-run",
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "pristine\n",
            "dry-run must not modify target file"
        );
    });
}
