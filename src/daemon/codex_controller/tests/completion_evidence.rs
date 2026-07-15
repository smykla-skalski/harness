use std::collections::BTreeSet;

use serde_json::json;

use crate::daemon::protocol::CodexRunStatus;
use crate::session::types::TaskStatus;

use super::durable_run_request;
use super::super::completion_evidence::{
    bound_task_has_completion_evidence, record_clean_worktree_baseline,
    worktree_changed_since_baseline,
};
use super::super::handle::record_snapshot_event;
use super::test_support::{
    codex_run_snapshot, controller_with_session_state, sample_session_state_with_open_task,
};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

#[test]
fn reconciliation_returns_normalized_failure_without_evidence() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let mut request = durable_run_request();
    request.task_id = Some("task-1".into());
    let agent_id = controller
        .register_orchestration_agent(
            SESSION_ID,
            "codex-run-1",
            &request,
            "Codex Worker",
        )
        .expect("register worker")
        .agent_id;
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);
    run.final_message = Some("Blocked before any command could run.".into());

    let reconciled = controller.reconcile_run(run).expect("reconcile run");

    assert_eq!(reconciled.status, CodexRunStatus::Failed);
    assert!(
        reconciled
            .error
            .as_deref()
            .is_some_and(|error| error.contains("Blocked before any command could run"))
    );
    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(state.tasks["task-1"].status, TaskStatus::Blocked);
}

#[test]
fn empty_commit_is_not_work_but_untracked_file_is() {
    let worktree = tempfile::tempdir().expect("worktree");
    harness_testkit::init_git_repo_with_seed(worktree.path());
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.project_dir = worktree.path().display().to_string();
    record_clean_worktree_baseline(&mut run);

    run_git(worktree.path(), &["commit", "--allow-empty", "-m", "empty"]);
    assert!(!worktree_changed_since_baseline(&run));

    fs_err::write(worktree.path().join("real-change.txt"), "changed\n")
        .expect("write real change");
    assert!(worktree_changed_since_baseline(&run));
}

#[test]
fn refreshed_baseline_requires_work_from_the_new_turn() {
    let worktree = tempfile::tempdir().expect("worktree");
    harness_testkit::init_git_repo_with_seed(worktree.path());
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.project_dir = worktree.path().display().to_string();
    record_clean_worktree_baseline(&mut run);

    fs_err::write(worktree.path().join("first-turn.txt"), "done\n")
        .expect("write first turn change");
    run_git(worktree.path(), &["add", "first-turn.txt"]);
    run_git(worktree.path(), &["commit", "-m", "first turn"]);
    record_snapshot_event(
        &mut run,
        "turn/completed",
        "First turn completed".into(),
        &json!({}),
    );
    record_clean_worktree_baseline(&mut run);
    assert!(!worktree_changed_since_baseline(&run));
    let event_ids = run
        .events
        .iter()
        .map(|event| event.event_id.as_str())
        .collect::<BTreeSet<_>>();
    let sequences = run
        .events
        .iter()
        .map(|event| event.sequence)
        .collect::<BTreeSet<_>>();
    assert_eq!(event_ids.len(), run.events.len());
    assert_eq!(sequences.len(), run.events.len());

    fs_err::write(worktree.path().join("second-turn.txt"), "done\n")
        .expect("write second turn change");
    assert!(worktree_changed_since_baseline(&run));
}

#[test]
fn dirty_follow_up_start_does_not_reuse_an_older_clean_baseline() {
    let worktree = tempfile::tempdir().expect("worktree");
    harness_testkit::init_git_repo_with_seed(worktree.path());
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.project_dir = worktree.path().display().to_string();
    record_clean_worktree_baseline(&mut run);

    fs_err::write(worktree.path().join("prior-turn.txt"), "still dirty\n")
        .expect("write prior turn change");
    assert!(worktree_changed_since_baseline(&run));

    record_clean_worktree_baseline(&mut run);
    let event = run.events.last().expect("dirty baseline event");
    assert_eq!(
        event.summary,
        "Worker worktree was not clean at turn start"
    );
    assert!(event.payload["tree"].is_null());
    assert!(!worktree_changed_since_baseline(&run));
}

#[test]
fn not_a_repository_reports_unavailable_worktree_baseline() {
    let worktree = tempfile::tempdir().expect("worktree");
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.project_dir = worktree.path().display().to_string();

    record_clean_worktree_baseline(&mut run);

    let event = run.events.last().expect("unavailable baseline event");
    assert_eq!(event.kind, "agent/worktree_baseline");
    assert_eq!(
        event.summary,
        "Worker worktree baseline could not be computed at turn start"
    );
    assert_ne!(
        event.summary,
        "Worker worktree was not clean at turn start"
    );
    assert!(event.payload["tree"].is_null());
}

#[test]
fn completed_review_is_durable_task_state_evidence() {
    let mut state = sample_session_state_with_open_task();
    state.tasks.get_mut("task-1").expect("task").status = TaskStatus::Done;
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some("agent-1".into());

    assert!(bound_task_has_completion_evidence(&state, &run));
}

fn run_git(worktree: &std::path::Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
