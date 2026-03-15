// Tests for runner workflow state management.
// Covers state initialization, read/write round-trips, phase transitions
// (preflight, abort, completed), and event tracking.

use harness::workflow::runner::{
    self as runner_workflow, PreflightStatus, RunnerEvent, RunnerPhase, RunnerWorkflowState,
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
    assert_eq!(state.schema_version, 2);
}

#[test]
fn runner_state_write_and_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-wf-rw", "single-zone");
    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("state exists");
    let new_state = state
        .transition(
            RunnerEvent::PreflightStarted,
            RunnerPhase::Preflight {
                status: PreflightStatus::Running,
            },
        )
        .unwrap();
    runner_workflow::write_runner_state(&run_dir, &new_state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("state exists");
    assert_eq!(
        reloaded.phase,
        RunnerPhase::Preflight {
            status: PreflightStatus::Running,
        }
    );
}

#[test]
fn runner_state_transitions_to_preflight() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-evt", "single-zone");
    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Bootstrap);
    let new_state = state
        .transition(
            RunnerEvent::PreflightStarted,
            RunnerPhase::Preflight {
                status: PreflightStatus::Running,
            },
        )
        .unwrap();
    runner_workflow::write_runner_state(&run_dir, &new_state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert!(matches!(reloaded.phase, RunnerPhase::Preflight { .. }));
}

#[test]
fn runner_state_abort_sets_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-abort", "single-zone");
    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    let aborted = state
        .transition(RunnerEvent::RunAborted, RunnerPhase::Aborted)
        .unwrap();
    runner_workflow::write_runner_state(&run_dir, &aborted).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Aborted);
}

#[test]
fn runner_state_completed_sets_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-complete", "single-zone");
    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    // Bootstrap -> Completed isn't a valid transition in the graph,
    // so construct directly to test serialization round-trip.
    let completed = RunnerWorkflowState {
        schema_version: 2,
        phase: RunnerPhase::Completed,
        updated_at: state.updated_at,
        transition_count: state.transition_count + 1,
        last_event: Some(RunnerEvent::RunCompleted),
    };
    runner_workflow::write_runner_state(&run_dir, &completed).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Completed);
}
