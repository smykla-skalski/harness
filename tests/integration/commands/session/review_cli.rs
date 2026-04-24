//! CLI → service → state integration coverage for the review workflow
//! subcommands added in Slice 4 (T21-T23) plus the improver apply
//! subcommand. Drives each command through `Cli::try_parse_from` and
//! `run_command` so the clap parser (incl. snake_case + kebab-case alias
//! surface) and the `Execute` dispatch are both exercised against real
//! session state.

use std::fs;

use clap::Parser;
use harness::app::cli::Cli;
use harness::session::service;
use harness::session::types::{AgentStatus, ReviewPointState, ReviewVerdict, TaskStatus};

use super::swarm_review_helpers::{
    join_reviewer, prepare_in_progress_task, setup_two_reviewers_on_claimed_task,
};
use super::with_session_test_env;
use crate::integration::helpers::run_command;

fn run_cli(args: &[&str]) -> i32 {
    let cli = Cli::try_parse_from(args).expect("parse cli");
    run_command(cli.command).expect("run cli")
}

#[test]
fn submit_for_review_via_cli_flips_task_and_worker() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-sfr", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        let (_leader, worker_id, task_id) = prepare_in_progress_task("rev-cli-1", &project);

        let exit = run_cli(&[
            "harness",
            "session",
            "task",
            "submit-for-review",
            "rev-cli-1",
            &task_id,
            "--actor",
            &worker_id,
            "--summary",
            "ready",
            "--suggested-persona",
            "code-reviewer",
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);

        let state = service::session_status("rev-cli-1", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::AwaitingReview);
        assert_eq!(
            task.suggested_persona.as_deref(),
            Some("code-reviewer"),
            "persona hint persisted"
        );
        let worker = state.agents.get(&worker_id).unwrap();
        assert_eq!(worker.status, AgentStatus::AwaitingReview);
    });
}

#[test]
fn claim_review_via_cli_moves_task_to_in_review() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-claim", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        let (_leader, worker_id, task_id) = prepare_in_progress_task("rev-cli-2", &project);
        service::submit_for_review("rev-cli-2", &task_id, &worker_id, None, &project)
            .expect("submit for review");
        let gemini_id = join_reviewer("rev-cli-2", "gemini", "GEMINI_SESSION_ID", &project);

        let exit = run_cli(&[
            "harness",
            "session",
            "task",
            "claim-review",
            "rev-cli-2",
            &task_id,
            "--actor",
            &gemini_id,
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);

        let state = service::session_status("rev-cli-2", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InReview);
        let claim = task.review_claim.as_ref().expect("claim recorded");
        assert!(
            claim
                .reviewers
                .iter()
                .any(|entry| entry.reviewer_agent_id == gemini_id),
            "CLI-driven claim appends reviewer entry"
        );
    });
}

#[test]
fn submit_review_via_cli_accepts_snake_case_verdict_and_json_points() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-sr-snake", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        let (_w, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("rev-cli-3", &project);

        let points_json = r#"[{"point_id":"p1","text":"needs docs","state":"open"}]"#;
        let exit = run_cli(&[
            "harness",
            "session",
            "task",
            "submit-review",
            "rev-cli-3",
            &task_id,
            "--actor",
            &gemini_id,
            "--verdict",
            "request_changes",
            "--summary",
            "missing docs",
            "--points",
            points_json,
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);

        // Second reviewer uses LEGACY kebab alias to prove back-compat.
        let exit2 = run_cli(&[
            "harness",
            "session",
            "task",
            "submit-review",
            "rev-cli-3",
            &task_id,
            "--actor",
            &claude_id,
            "--verdict",
            "request-changes",
            "--summary",
            "agree",
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit2, 0);

        let state = service::session_status("rev-cli-3", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        let consensus = task.consensus.as_ref().expect("quorum recorded");
        assert_eq!(consensus.verdict, ReviewVerdict::RequestChanges);
        assert!(
            consensus
                .points
                .iter()
                .any(|point| point.point_id == "p1"),
            "point id from --points JSON folded into consensus"
        );
    });
}

#[test]
fn respond_review_via_cli_splits_csv_into_agreed_and_disputed() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-respond", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        let (worker_id, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("rev-cli-4", &project);

        let points = r#"[
            {"point_id":"p1","text":"A","state":"open"},
            {"point_id":"p2","text":"B","state":"open"}
        ]"#;
        for reviewer in [&gemini_id, &claude_id] {
            let _ = run_cli(&[
                "harness",
                "session",
                "task",
                "submit-review",
                "rev-cli-4",
                &task_id,
                "--actor",
                reviewer,
                "--verdict",
                "request_changes",
                "--summary",
                "round",
                "--points",
                points,
                "--project-dir",
                &project_str,
            ]);
        }

        let exit = run_cli(&[
            "harness",
            "session",
            "task",
            "respond-review",
            "rev-cli-4",
            &task_id,
            "--actor",
            &worker_id,
            "--agreed",
            "p1",
            "--disputed",
            "p2",
            "--note",
            "redoing p2",
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);

        let state = service::session_status("rev-cli-4", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.review_round, 1, "respond-review bumps round counter");
        let history = task
            .review_history
            .last()
            .expect("prior consensus archived to review_history");
        let p1 = history
            .points
            .iter()
            .find(|point| point.point_id == "p1")
            .unwrap();
        let p2 = history
            .points
            .iter()
            .find(|point| point.point_id == "p2")
            .unwrap();
        assert_eq!(p1.state, ReviewPointState::Resolved);
        assert_eq!(p2.state, ReviewPointState::Disputed);
    });
}

#[test]
fn arbitrate_via_cli_requires_third_round_and_closes_task_on_approve() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-arb", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        let (worker_id, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("rev-cli-5", &project);

        // Drive three rounds of request_changes + dispute to arm the
        // arbitration gate (review_round >= 3).
        let points = r#"[{"point_id":"p1","text":"X","state":"open"}]"#;
        for _ in 0..3 {
            for reviewer in [&gemini_id, &claude_id] {
                let _ = run_cli(&[
                    "harness",
                    "session",
                    "task",
                    "submit-review",
                    "rev-cli-5",
                    &task_id,
                    "--actor",
                    reviewer,
                    "--verdict",
                    "request_changes",
                    "--summary",
                    "round",
                    "--points",
                    points,
                    "--project-dir",
                    &project_str,
                ]);
            }
            let _ = run_cli(&[
                "harness",
                "session",
                "task",
                "respond-review",
                "rev-cli-5",
                &task_id,
                "--actor",
                &worker_id,
                "--disputed",
                "p1",
                "--project-dir",
                &project_str,
            ]);
        }

        let leader_id = service::session_status("rev-cli-5", &project)
            .unwrap()
            .leader_id
            .expect("leader present");
        let exit = run_cli(&[
            "harness",
            "session",
            "task",
            "arbitrate",
            "rev-cli-5",
            &task_id,
            "--actor",
            &leader_id,
            "--verdict",
            "approve",
            "--summary",
            "shipping",
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);

        let state = service::session_status("rev-cli-5", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        let arb = task.arbitration.as_ref().expect("arbitration recorded");
        assert_eq!(arb.verdict, ReviewVerdict::Approve);
        assert_eq!(task.status, TaskStatus::Done);
    });
}

#[test]
fn improver_apply_via_cli_writes_file_and_prints_outcome() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-improver", || {
        let project = tmp.path().join("project");
        fs::create_dir_all(project.join("agents/skills/demo")).unwrap();
        fs::write(project.join("agents/skills/demo/SKILL.md"), "old\n").unwrap();
        let contents_file = tmp.path().join("new-contents.md");
        fs::write(&contents_file, "new\n").unwrap();

        // Start + join a leader so actor resolves; improver apply itself
        // does not gate on session state, but the arg is required.
        let _state = service::start_session_with_policy(
            "",
            "improver cli",
            &project,
            Some("rev-cli-6"),
            Some("swarm-default"),
        )
        .unwrap();
        let joined = service::join_session(
            "rev-cli-6",
            harness::session::types::SessionRole::Leader,
            "claude",
            &[],
            Some("improver-persona"),
            &project,
            None,
        )
        .unwrap();
        let actor = joined.leader_id.unwrap();

        let project_str = project.to_string_lossy().to_string();
        let contents_str = contents_file.to_string_lossy().to_string();
        let exit = run_cli(&[
            "harness",
            "session",
            "improver",
            "apply",
            "rev-cli-6",
            "--actor",
            &actor,
            "--issue-id",
            "python_traceback_output/abc",
            "--target",
            "skill",
            "--rel-path",
            "demo/SKILL.md",
            "--new-contents-file",
            &contents_str,
            "--project-dir",
            &project_str,
        ]);
        assert_eq!(exit, 0);

        let on_disk = fs::read_to_string(project.join("agents/skills/demo/SKILL.md")).unwrap();
        assert_eq!(on_disk, "new\n");
    });
}

#[test]
fn improver_apply_dry_run_leaves_file_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-rev-cli-improver-dry", || {
        let project = tmp.path().join("project");
        fs::create_dir_all(project.join("agents/skills/demo")).unwrap();
        let target = project.join("agents/skills/demo/SKILL.md");
        fs::write(&target, "pristine\n").unwrap();
        let contents_file = tmp.path().join("new.md");
        fs::write(&contents_file, "would-write\n").unwrap();

        let _state = service::start_session_with_policy(
            "",
            "improver dry",
            &project,
            Some("rev-cli-7"),
            Some("swarm-default"),
        )
        .unwrap();
        let joined = service::join_session(
            "rev-cli-7",
            harness::session::types::SessionRole::Leader,
            "claude",
            &[],
            None,
            &project,
            None,
        )
        .unwrap();
        let actor = joined.leader_id.unwrap();

        let project_str = project.to_string_lossy().to_string();
        let contents_str = contents_file.to_string_lossy().to_string();
        let exit = run_cli(&[
            "harness",
            "session",
            "improver",
            "apply",
            "rev-cli-7",
            "--actor",
            &actor,
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
