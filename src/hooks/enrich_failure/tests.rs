use super::*;
use crate::run::workflow::{PreflightState, PreflightStatus};

fn base_state() -> RunnerWorkflowState {
    RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
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
fn request_failure_triage_sets_phase_and_failure() {
    let state = base_state();
    let result = request_failure_triage(&state, FailureKind::Manifest);
    assert_eq!(result.phase, RunnerPhase::Triage);
    assert!(result.failure.is_some());
    assert_eq!(result.failure.unwrap().kind, FailureKind::Manifest);
    assert_eq!(result.transition_count, 1);
    assert_eq!(result.last_event.as_deref(), Some("FailureTriageRequested"));
}

#[test]
fn request_preflight_failed_resets_status() {
    let mut state = base_state();
    state.phase = RunnerPhase::Preflight;
    state.preflight.status = PreflightStatus::Running;
    let result = request_preflight_failed(&state);
    assert_eq!(result.preflight.status, PreflightStatus::Pending);
    assert_eq!(result.transition_count, 1);
    assert_eq!(result.last_event.as_deref(), Some("PreflightFailed"));
}
