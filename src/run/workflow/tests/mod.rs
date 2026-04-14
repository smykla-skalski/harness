use super::*;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

use persistence::make_initial_state;

mod phase_transitions;

fn bootstrap_state() -> RunnerWorkflowState {
    make_initial_state("2025-01-01T00:00:00Z")
}

fn assert_next_action(
    state: &RunnerWorkflowState,
    expected: RunnerNextAction,
    expected_text: &str,
) {
    assert_eq!(next_action(Some(state)), expected);
    assert!(next_action(Some(state)).to_string().contains(expected_text));
}

fn setup_execution_phase() -> TempDir {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
    apply_event(dir.path(), "preflight-captured", None, None).unwrap();
    dir
}

#[test]
fn runner_phase_display() {
    let cases = [
        (RunnerPhase::Bootstrap, "bootstrap"),
        (RunnerPhase::Preflight, "preflight"),
        (RunnerPhase::Execution, "execution"),
        (RunnerPhase::Triage, "triage"),
        (RunnerPhase::Closeout, "closeout"),
        (RunnerPhase::Completed, "completed"),
        (RunnerPhase::Aborted, "aborted"),
        (RunnerPhase::Suspended, "suspended"),
    ];
    for (variant, expected) in cases {
        assert_eq!(variant.to_string(), expected);
    }
}

#[test]
fn runner_phase_serialization_round_trip() {
    let state = bootstrap_state();
    let json = serde_json::to_value(&state).unwrap();
    assert_eq!(json["state"]["phase"], "bootstrap");
    assert_eq!(json["state"]["preflight"]["status"], "pending");
    let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
    assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
}

#[test]
fn failure_kind_serialization() {
    let f = FailureState {
        kind: FailureKind::Manifest,
        suite_target: Some("groups/g1".to_string()),
        message: None,
    };
    let json = serde_json::to_value(&f).unwrap();
    assert_eq!(json["kind"], "manifest");
    assert_eq!(json["suite_target"], "groups/g1");
    assert!(json.get("message").is_none());
}

#[test]
fn manifest_fix_decision_serialization() {
    let json = serde_json::to_value(ManifestFixDecision::SuiteAndRun).unwrap();
    assert_eq!(json, "Fix in suite and this run");
    let loaded: ManifestFixDecision = serde_json::from_value(json).unwrap();
    assert_eq!(loaded, ManifestFixDecision::SuiteAndRun);
}

#[test]
fn suite_fix_ready_to_resume_both_true() {
    let fix = SuiteFixState {
        approved_paths: vec!["a".to_string()],
        suite_written: true,
        amendments_written: true,
        decision: ManifestFixDecision::SuiteAndRun,
    };
    assert!(fix.ready_to_resume());
}

#[test]
fn suite_fix_not_ready_when_partial() {
    let fix = SuiteFixState {
        approved_paths: vec![],
        suite_written: true,
        amendments_written: false,
        decision: ManifestFixDecision::SuiteAndRun,
    };
    assert!(!fix.ready_to_resume());
}

#[test]
fn initialize_and_read_round_trip() {
    let dir = TempDir::new().unwrap();
    let state = initialize_runner_state(dir.path()).unwrap();
    assert_eq!(state.phase, RunnerPhase::Bootstrap);
    assert_eq!(state.transition_count, 0);
    let loaded = read_runner_state(dir.path()).unwrap().unwrap();
    assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
}

#[test]
fn write_and_read_runner_state() {
    let dir = TempDir::new().unwrap();
    let mut state = bootstrap_state();
    state.phase = RunnerPhase::Execution;
    state.transition_count = 3;
    write_runner_state(dir.path(), &state).unwrap();
    let loaded = read_runner_state(dir.path()).unwrap().unwrap();
    assert_eq!(loaded.phase, RunnerPhase::Execution);
    assert_eq!(loaded.transition_count, 3);
}

#[test]
fn read_returns_none_when_missing() {
    let dir = TempDir::new().unwrap();
    assert!(read_runner_state(dir.path()).unwrap().is_none());
}

#[test]
fn next_action_none_state() {
    assert_eq!(next_action(None), RunnerNextAction::ReloadState);
    assert!(next_action(None).to_string().contains("Reload"));
}

#[test]
fn next_action_each_phase() {
    let mut state = bootstrap_state();
    assert_next_action(&state, RunnerNextAction::FinishBootstrap, "bootstrap");

    state.phase = RunnerPhase::Preflight;
    assert_next_action(&state, RunnerNextAction::ExecutePreflight, "preflight");

    state.preflight.status = PreflightStatus::Running;
    assert_next_action(
        &state,
        RunnerNextAction::FinishPreflightWorker,
        "preflight worker",
    );

    state.phase = RunnerPhase::Execution;
    assert_next_action(&state, RunnerNextAction::ContinueExecution, "execution");

    state.phase = RunnerPhase::Triage;
    assert_next_action(&state, RunnerNextAction::ResolveTriage, "triage");

    state.phase = RunnerPhase::Closeout;
    assert_next_action(&state, RunnerNextAction::FinishCloseout, "closeout");

    state.phase = RunnerPhase::Completed;
    assert_next_action(&state, RunnerNextAction::ReviewReport, "final verdict");

    state.phase = RunnerPhase::Aborted;
    assert_next_action(&state, RunnerNextAction::HandleAbort, "guard-stop");

    state.phase = RunnerPhase::Suspended;
    assert_next_action(&state, RunnerNextAction::ResumeRun, "suspended");
}

#[test]
fn next_action_triage_with_suite_fix() {
    let mut state = bootstrap_state();
    state.phase = RunnerPhase::Triage;
    state.suite_fix = Some(SuiteFixState {
        approved_paths: vec![],
        suite_written: false,
        amendments_written: false,
        decision: ManifestFixDecision::SuiteAndRun,
    });
    assert_eq!(
        next_action(Some(&state)),
        RunnerNextAction::FinishSuiteRepair
    );
    assert!(
        next_action(Some(&state))
            .to_string()
            .contains("suite repair")
    );
}

#[test]
fn runner_state_path_builds_correctly() {
    let path = runner_state_path(Path::new("/runs/r1"));
    assert_eq!(path, PathBuf::from("/runs/r1/suite-run-state.json"));
}

#[test]
fn full_state_serialization_with_all_fields() {
    let state = RunnerWorkflowState {
        phase: RunnerPhase::Triage,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: Some(FailureState {
            kind: FailureKind::Manifest,
            suite_target: Some("groups/g1".to_string()),
            message: Some("test failed".to_string()),
        }),
        suite_fix: Some(SuiteFixState {
            approved_paths: vec!["groups/g1".to_string()],
            suite_written: true,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        }),
        updated_at: "2025-01-01T00:00:00Z".to_string(),
        transition_count: 5,
        last_event: Some("ManifestFixAnswered".to_string()),
        history: Vec::new(),
    };
    let json = serde_json::to_value(&state).unwrap();
    let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
    assert_eq!(loaded, state);
}

#[test]
fn preflight_status_variants_serialize() {
    for (variant, expected) in [
        (PreflightStatus::Pending, "pending"),
        (PreflightStatus::Running, "running"),
        (PreflightStatus::Complete, "complete"),
    ] {
        let json = serde_json::to_value(variant).unwrap();
        assert_eq!(json, expected);
    }
}

#[test]
fn failure_kind_variants_serialize() {
    for (variant, expected) in [
        (FailureKind::Manifest, "manifest"),
        (FailureKind::Environment, "environment"),
        (FailureKind::Product, "product"),
    ] {
        let json = serde_json::to_value(variant).unwrap();
        assert_eq!(json, expected);
    }
}

#[test]
fn manifest_fix_decision_all_variants() {
    let cases = [
        (ManifestFixDecision::RunOnly, "Fix for this run only"),
        (
            ManifestFixDecision::SuiteAndRun,
            "Fix in suite and this run",
        ),
        (ManifestFixDecision::SkipStep, "Skip this step"),
        (ManifestFixDecision::StopRun, "Stop run"),
    ];
    for (variant, expected) in cases {
        let json = serde_json::to_value(variant).unwrap();
        assert_eq!(json, expected);
    }
}
