// Tests for runner workflow state management.
// Covers state initialization, read/write round-trips, phase transitions
// (preflight, abort, completed), and event tracking.

use harness::commands::RunDirArgs;
use harness::commands::run::runner_state;
use harness::workflow::runner::{
    self as runner_workflow, PreflightStatus, RunnerEvent, RunnerPhase,
};

use super::super::helpers::*;

#[test]
fn runner_state_initialize_and_read() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-wf", "single-zone");
    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("runner state should exist");
    assert_eq!(state.phase, RunnerPhase::Bootstrap);
    assert_eq!(state.preflight.status, PreflightStatus::Pending);
    assert_eq!(state.schema_version, 2);
}

#[test]
fn runner_state_write_and_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-wf-rw", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("state exists");
    state.phase = RunnerPhase::Preflight;
    state.preflight.status = PreflightStatus::Running;
    state.transition_count += 1;
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("state exists");
    assert_eq!(reloaded.phase, RunnerPhase::Preflight);
    assert_eq!(reloaded.preflight.status, PreflightStatus::Running);
}

#[test]
fn runner_state_transitions_to_preflight() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-evt", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Bootstrap);
    state.phase = RunnerPhase::Preflight;
    state.preflight.status = PreflightStatus::Running;
    state.transition_count += 1;
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Preflight);
}

#[test]
fn runner_state_abort_sets_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-abort", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    state.phase = RunnerPhase::Aborted;
    state.last_event = Some("RunAborted".to_string());
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Aborted);
}

#[test]
fn runner_state_completed_sets_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-complete", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    state.phase = RunnerPhase::Completed;
    state.last_event = Some("RunCompleted".to_string());
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Completed);
}

#[test]
fn runner_state_event_returns_error() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-evt-err", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };
    let result = runner_state(Some(RunnerEvent::RunCompleted), None, None, &args);
    assert!(result.is_err(), "event-based transitions should return Err");
    let err = result.unwrap_err();
    assert_eq!(err.code(), "KSRCLI084");
}
