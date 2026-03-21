use std::fs;

use serde_json::json;
use tempfile::TempDir;

use super::*;
use crate::run::workflow::{ManifestFixDecision, SuiteFixState};

#[test]
fn read_runner_state_rejects_legacy_flat_state() {
    let dir = TempDir::new().unwrap();
    let path = runner_state_path(dir.path());
    let v1 = json!({
        "phase": "triage",
        "preflight": { "status": "complete" },
        "failure": null,
        "suite_fix": {
            "approved_paths": ["groups/demo.md"],
            "suite_written": true,
            "amendments_written": false,
            "decision": "Fix in suite and this run"
        },
        "updated_at": "2025-01-01T00:00:00Z",
        "transition_count": 4,
        "last_event": "ManifestFixAnswered"
    });
    fs::write(&path, serde_json::to_string_pretty(&v1).unwrap()).unwrap();

    let error = read_runner_state(dir.path()).unwrap_err();
    assert_eq!(error.code(), "WORKFLOW_PARSE");
    assert!(
        error
            .details()
            .unwrap_or_default()
            .contains("harness run init")
    );
}

#[test]
fn read_runner_state_ignores_legacy_file_name() {
    let dir = TempDir::new().unwrap();
    let legacy_path = dir.path().join("runner-state.json");
    let v1 = json!({
        "state": {
            "phase": "bootstrap",
            "preflight": { "status": "pending" }
        },
        "updated_at": "2025-01-01T00:00:00Z",
        "transition_count": 0,
        "last_event": "RunInitialized"
    });
    fs::write(&legacy_path, serde_json::to_string_pretty(&v1).unwrap()).unwrap();

    let state = read_runner_state(dir.path()).unwrap();
    assert!(state.is_none());
    assert!(!runner_state_path(dir.path()).exists());
}

#[test]
fn write_runner_state_persists_strict_shape() {
    let dir = TempDir::new().unwrap();
    let mut state = make_initial_state("2025-01-01T00:00:00Z");
    state.phase = RunnerPhase::Execution;
    state.transition_count = 3;
    write_runner_state(dir.path(), &state).unwrap();

    let json: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(runner_state_path(dir.path())).unwrap()).unwrap();
    assert!(json.get("schema_version").is_none());
    assert_eq!(json["state"]["phase"], "execution");
}

#[test]
fn write_runner_state_if_current_rejects_conflict() {
    let dir = TempDir::new().unwrap();
    let mut state = make_initial_state("2025-01-01T00:00:00Z");
    state.phase = RunnerPhase::Triage;
    state.transition_count = 3;
    state.suite_fix = Some(SuiteFixState {
        approved_paths: vec![],
        suite_written: false,
        amendments_written: false,
        decision: ManifestFixDecision::SuiteAndRun,
    });
    write_runner_state(dir.path(), &state).unwrap();

    let mut next = state;
    next.transition_count = 4;
    next.suite_fix = Some(SuiteFixState {
        approved_paths: vec![],
        suite_written: true,
        amendments_written: false,
        decision: ManifestFixDecision::SuiteAndRun,
    });

    let error = write_runner_state_if_current(dir.path(), 2, &next).unwrap_err();
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}
