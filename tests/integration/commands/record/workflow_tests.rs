use std::env;
use std::fs;

use harness::create::{read_create_state, ApprovalBeginArgs, CreatePhase};
use harness::run::workflow::{self as runner_workflow, RunnerPhase};
use harness::run::{CloseoutArgs, RunDirArgs, Verdict};

use super::super::super::helpers::*;

#[test]
fn cluster_up_rejects_finalized_run_reuse() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-cluster", "single-zone");

    let mut state = harness_testkit::read_runner_state(&run_dir).unwrap();
    state.phase = RunnerPhase::Completed;
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();

    let reloaded = harness_testkit::read_runner_state(&run_dir).unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Completed);
}

#[test]
fn approval_begin_initializes_interactive_state() {
    let tmp = tempfile::tempdir().unwrap();
    let work_dir = tmp.path().join("project");
    fs::create_dir_all(&work_dir).unwrap();

    let prev_dir = env::current_dir().unwrap();
    env::set_current_dir(&work_dir).unwrap();

    let result = approval_begin_cmd(ApprovalBeginArgs {
        mode: "interactive".to_string(),
        suite_dir: None,
    })
    .execute();
    assert!(result.is_ok(), "approval_begin should succeed: {result:?}");

    let state = read_create_state().unwrap().unwrap();
    assert_eq!(state.phase, CreatePhase::Discovery);

    env::set_current_dir(&prev_dir).unwrap();
}

#[test]
fn closeout_sets_completed_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-closeout", "single-zone");

    fs::write(run_dir.join("run-report.md"), "# Report\n").unwrap();
    let cmd_log = run_dir.join("commands").join("command-log.md");
    fs::write(&cmd_log, "| ran_at | command | exit_code | artifact |\n").unwrap();
    let manifest_idx = run_dir.join("manifests").join("manifest-index.md");
    fs::write(&manifest_idx, "| path | step |\n").unwrap();

    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.last_state_capture = Some("state/capture-1.json".into());
    write_run_status(&run_dir, &status);

    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    let result = closeout_cmd(CloseoutArgs { run_dir: args }).execute();
    assert!(result.is_ok(), "closeout should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}
