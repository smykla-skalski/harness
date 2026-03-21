use super::runtime::can_start_preflight_worker;
use crate::run::workflow::PreflightState;
use crate::run::workflow::{PreflightStatus, RunnerPhase, RunnerWorkflowState};

fn base_state(phase: RunnerPhase, preflight_status: PreflightStatus) -> RunnerWorkflowState {
    RunnerWorkflowState {
        phase,
        preflight: PreflightState {
            status: preflight_status,
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
fn preflight_pending_allows_start() {
    let state = base_state(RunnerPhase::Preflight, PreflightStatus::Pending);
    let (allowed, reason) = can_start_preflight_worker(&state);
    assert!(allowed);
    assert!(reason.is_none());
}

#[test]
fn preflight_running_allows_start() {
    let state = base_state(RunnerPhase::Preflight, PreflightStatus::Running);
    let (allowed, reason) = can_start_preflight_worker(&state);
    assert!(allowed);
    assert!(reason.is_none());
}

#[test]
fn bootstrap_phase_denies_start() {
    let state = base_state(RunnerPhase::Bootstrap, PreflightStatus::Pending);
    let (allowed, reason) = can_start_preflight_worker(&state);
    assert!(!allowed);
    assert!(reason.is_some());
}

#[test]
fn preflight_complete_denies_start() {
    let state = base_state(RunnerPhase::Preflight, PreflightStatus::Complete);
    let (allowed, reason) = can_start_preflight_worker(&state);
    assert!(!allowed);
    assert!(reason.unwrap().contains("already complete"));
}
