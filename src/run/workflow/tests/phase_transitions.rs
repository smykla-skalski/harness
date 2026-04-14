use tempfile::TempDir;

use super::super::transitions::{event_label, is_valid_transition};
use super::*;

#[test]
fn apply_event_cluster_prepared_advances_to_preflight() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Preflight);
    assert_eq!(state.transition_count, 1);
    assert_eq!(state.last_event.as_deref(), Some("ClusterPrepared"));
}

#[test]
fn apply_event_reaches_execution_after_preflight() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();

    let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Preflight);

    let state = apply_event(dir.path(), "preflight-started", None, None).unwrap();
    assert_eq!(state.preflight.status, PreflightStatus::Running);

    let state = apply_event(dir.path(), "preflight-captured", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
    assert_eq!(state.preflight.status, PreflightStatus::Complete);
}

#[test]
fn apply_event_reaches_completed_after_closeout() {
    let dir = setup_execution_phase();

    let closeout = apply_event(dir.path(), "closeout-started", None, None).unwrap();
    assert_eq!(closeout.phase, RunnerPhase::Closeout);

    let state = apply_event(dir.path(), "run-completed", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Completed);
    assert_eq!(state.transition_count, 4);
}

#[test]
fn apply_event_abort_from_execution() {
    let dir = setup_execution_phase();
    let state = apply_event(dir.path(), "abort", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Aborted);
}

#[test]
fn apply_event_suspend_and_resume() {
    let dir = setup_execution_phase();

    let state = apply_event(dir.path(), "suspend", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Suspended);

    let state = apply_event(dir.path(), "resume-run", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
}

#[test]
fn apply_event_resume_from_aborted() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "abort", None, None).unwrap();

    let state = apply_event(dir.path(), "resume-run", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
}

#[test]
fn apply_event_invalid_transition_rejected() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();

    let result = apply_event(dir.path(), "closeout-started", None, None);
    assert!(result.is_err());
    let error = result.unwrap_err();
    assert_eq!(error.code(), "KSRCLI084");
}

#[test]
fn apply_event_unknown_event_rejected() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();

    let result = apply_event(dir.path(), "made-up-event", None, None);
    assert!(result.is_err());
    assert!(result.unwrap_err().message().contains("unknown event"));
}

#[test]
fn apply_event_failure_manifest_sets_triage() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();

    let state = apply_event(
        dir.path(),
        "failure-manifest",
        Some("groups/g1.md"),
        Some("parse error"),
    )
    .unwrap();
    assert_eq!(state.phase, RunnerPhase::Triage);
    assert!(state.failure.is_some());
    let failure = state.failure.unwrap();
    assert_eq!(failure.kind, FailureKind::Manifest);
    assert_eq!(failure.suite_target.as_deref(), Some("groups/g1.md"));
    assert_eq!(failure.message.as_deref(), Some("parse error"));
}

#[test]
fn apply_event_manifest_fix_suite_and_run_sets_suite_fix() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "failure-manifest", Some("groups/g1.md"), None).unwrap();

    let state = apply_event(
        dir.path(),
        "manifest-fix-suite-and-run",
        Some("groups/g1.md"),
        None,
    )
    .unwrap();
    assert_eq!(state.phase, RunnerPhase::Triage);
    let fix = state.suite_fix.unwrap();
    assert_eq!(fix.decision, ManifestFixDecision::SuiteAndRun);
    assert_eq!(fix.approved_paths, vec!["groups/g1.md"]);
    assert!(!fix.suite_written);
    assert!(!fix.amendments_written);
}

#[test]
fn apply_event_manifest_fix_stop_run_aborts() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "failure-manifest", None, None).unwrap();

    let state = apply_event(dir.path(), "manifest-fix-stop-run", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Aborted);
}

#[test]
fn apply_event_suite_fix_resumed_returns_to_execution() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "failure-manifest", None, None).unwrap();
    apply_event(dir.path(), "manifest-fix-run-only", None, None).unwrap();

    let state = apply_event(dir.path(), "suite-fix-resumed", None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
    assert!(state.suite_fix.is_none());
}

#[test]
fn apply_event_cannot_transition_from_completed() {
    let dir = setup_execution_phase();
    apply_event(dir.path(), "closeout-started", None, None).unwrap();
    apply_event(dir.path(), "run-completed", None, None).unwrap();

    let result = apply_event(dir.path(), "abort", None, None);
    assert!(result.is_err());
}

#[test]
fn ensure_execution_phase_from_bootstrap() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();

    let advanced = ensure_execution_phase(dir.path()).unwrap();
    assert!(advanced);

    let state = read_runner_state(dir.path()).unwrap().unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
    assert_eq!(state.last_event.as_deref(), Some("AutoAdvanceToExecution"));
}

#[test]
fn ensure_execution_phase_from_preflight() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "cluster-prepared", None, None).unwrap();

    let advanced = ensure_execution_phase(dir.path()).unwrap();
    assert!(advanced);

    let state = read_runner_state(dir.path()).unwrap().unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
}

#[test]
fn ensure_execution_phase_noop_when_already_executing() {
    let dir = setup_execution_phase();

    let advanced = ensure_execution_phase(dir.path()).unwrap();
    assert!(!advanced);

    let state = read_runner_state(dir.path()).unwrap().unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
}

#[test]
fn ensure_execution_phase_noop_when_no_state() {
    let dir = TempDir::new().unwrap();
    let advanced = ensure_execution_phase(dir.path()).unwrap();
    assert!(!advanced);
}

#[test]
fn event_label_camel_cases_dashed_name() {
    assert_eq!(event_label("cluster-prepared"), "ClusterPrepared");
    assert_eq!(event_label("preflight-started"), "PreflightStarted");
    assert_eq!(event_label("abort"), "Abort");
    assert_eq!(
        event_label("manifest-fix-suite-and-run"),
        "ManifestFixSuiteAndRun"
    );
}

#[test]
fn valid_transitions_from_bootstrap() {
    assert!(is_valid_transition(
        RunnerPhase::Bootstrap,
        RunnerPhase::Preflight,
        "cluster-prepared"
    ));
    assert!(is_valid_transition(
        RunnerPhase::Bootstrap,
        RunnerPhase::Execution,
        "preflight-captured"
    ));
    assert!(is_valid_transition(
        RunnerPhase::Bootstrap,
        RunnerPhase::Aborted,
        "abort"
    ));
    assert!(!is_valid_transition(
        RunnerPhase::Bootstrap,
        RunnerPhase::Closeout,
        "closeout-started"
    ));
}

#[test]
fn valid_transitions_from_execution() {
    assert!(is_valid_transition(
        RunnerPhase::Execution,
        RunnerPhase::Closeout,
        "closeout-started"
    ));
    assert!(is_valid_transition(
        RunnerPhase::Execution,
        RunnerPhase::Triage,
        "failure-manifest"
    ));
    assert!(is_valid_transition(
        RunnerPhase::Execution,
        RunnerPhase::Suspended,
        "suspend"
    ));
    assert!(!is_valid_transition(
        RunnerPhase::Execution,
        RunnerPhase::Preflight,
        "preflight-started"
    ));
}

#[test]
fn resume_only_from_suspended_or_aborted() {
    assert!(is_valid_transition(
        RunnerPhase::Suspended,
        RunnerPhase::Execution,
        "resume-run"
    ));
    assert!(is_valid_transition(
        RunnerPhase::Aborted,
        RunnerPhase::Execution,
        "resume-run"
    ));
    assert!(!is_valid_transition(
        RunnerPhase::Execution,
        RunnerPhase::Execution,
        "resume-run"
    ));
}

#[test]
fn snapshot_initial_state() {
    let state = make_initial_state("2026-01-01T00:00:00Z");
    let json = serde_json::to_value(&state).expect("serialize state");
    insta::assert_snapshot!(serde_json::to_string_pretty(&json).unwrap());
}

fn redact_timestamps(json: &mut serde_json::Value) {
    json["updated_at"] = serde_json::json!("REDACTED");
    json["state"]["updated_at"] = serde_json::json!("REDACTED");
    if let Some(history) = json["state"]["history"].as_array_mut() {
        for entry in history {
            entry["timestamp"] = serde_json::json!("REDACTED");
        }
    }
}

#[test]
fn snapshot_state_after_cluster_prepared() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
    let mut json = serde_json::to_value(&state).expect("serialize state");
    redact_timestamps(&mut json);
    insta::assert_snapshot!(serde_json::to_string_pretty(&json).unwrap());
}

#[test]
fn snapshot_state_after_full_happy_path() {
    let dir = TempDir::new().unwrap();
    initialize_runner_state(dir.path()).unwrap();
    apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
    apply_event(dir.path(), "preflight-captured", None, None).unwrap();
    apply_event(dir.path(), "closeout-started", None, None).unwrap();
    let state = apply_event(dir.path(), "run-completed", None, None).unwrap();
    let mut json = serde_json::to_value(&state).expect("serialize state");
    redact_timestamps(&mut json);
    insta::assert_snapshot!(serde_json::to_string_pretty(&json).unwrap());
}
