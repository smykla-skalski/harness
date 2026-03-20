use super::*;
use crate::run::workflow::{
    FailureKind, FailureState, PreflightState, PreflightStatus, RunnerWorkflowState,
};

fn base_state(phase: RunnerPhase) -> RunnerWorkflowState {
    RunnerWorkflowState {
        phase,
        preflight: PreflightState {
            status: PreflightStatus::Pending,
        },
        failure: None,
        suite_fix: None,
        updated_at: String::new(),
        transition_count: 0,
        last_event: None,
        history: Vec::new(),
    }
}

#[test]
fn triage_with_failure_allows_manifest_fix() {
    let mut state = base_state(RunnerPhase::Triage);
    state.failure = Some(FailureState {
        kind: FailureKind::Manifest,
        suite_target: None,
        message: None,
    });
    let (allowed, reason) = can_ask_manifest_fix(&state);
    assert!(allowed);
    assert!(reason.is_none());
}

#[test]
fn execution_phase_denies_manifest_fix() {
    let state = base_state(RunnerPhase::Execution);
    let (allowed, reason) = can_ask_manifest_fix(&state);
    assert!(!allowed);
    assert!(reason.is_some());
}

#[test]
fn triage_without_failure_denies_manifest_fix() {
    let state = base_state(RunnerPhase::Triage);
    let (allowed, reason) = can_ask_manifest_fix(&state);
    assert!(!allowed);
    assert!(reason.unwrap().contains("no failure"));
}
