use super::*;
use std::fs;

use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::run::workflow::{
    FailureKind, FailureState, ManifestFixDecision, PreflightState, PreflightStatus,
    RunnerWorkflowState,
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

// -- subcommand_artifacts --

#[test]
fn subcommand_artifacts_apply() {
    let arts = subcommand_artifacts("apply").unwrap();
    assert!(arts.contains(&"manifests"));
}

#[test]
fn subcommand_artifacts_capture() {
    let arts = subcommand_artifacts("capture").unwrap();
    assert!(arts.contains(&"state"));
}

#[test]
fn subcommand_artifacts_record() {
    let arts = subcommand_artifacts("record").unwrap();
    assert!(arts.contains(&"commands"));
}

#[test]
fn subcommand_artifacts_unknown() {
    assert!(subcommand_artifacts("unknown").is_none());
}

// -- has_table_rows --

#[test]
fn has_table_rows_with_enough_rows() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    fs::write(tmp.path(), "| h1 | h2 |\n|---|---|\n| a | b |\n| c | d |\n").unwrap();
    assert!(has_table_rows(tmp.path()));
}

#[test]
fn has_table_rows_with_too_few() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    fs::write(tmp.path(), "| h1 | h2 |\n|---|---|\n").unwrap();
    assert!(!has_table_rows(tmp.path()));
}

#[test]
fn has_table_rows_missing_file() {
    assert!(!has_table_rows(Path::new("/nonexistent/path/file.md")));
}

// -- ready_to_resume --

#[test]
fn ready_to_resume_triage_with_suite_fix_ready() {
    let mut state = base_state(RunnerPhase::Triage);
    state.suite_fix = Some(SuiteFixState {
        approved_paths: vec![],
        suite_written: true,
        amendments_written: true,
        decision: ManifestFixDecision::SuiteAndRun,
    });
    assert!(ready_to_resume(&state));
}

#[test]
fn ready_to_resume_wrong_phase() {
    let state = base_state(RunnerPhase::Execution);
    assert!(!ready_to_resume(&state));
}

#[test]
fn ready_to_resume_no_suite_fix() {
    let state = base_state(RunnerPhase::Triage);
    assert!(!ready_to_resume(&state));
}

#[test]
fn ready_to_resume_suite_fix_incomplete() {
    let mut state = base_state(RunnerPhase::Triage);
    state.suite_fix = Some(SuiteFixState {
        approved_paths: vec![],
        suite_written: true,
        amendments_written: false,
        decision: ManifestFixDecision::SuiteAndRun,
    });
    assert!(!ready_to_resume(&state));
}

// -- response_contains_failure --

#[test]
fn response_contains_failure_detects_error_code() {
    assert!(response_contains_failure(
        "ERROR [KSRCLI004] command failed: harness apply"
    ));
}

#[test]
fn response_contains_failure_detects_missing_file_code() {
    assert!(response_contains_failure(
        "ERROR [KSRCLI014] missing file: /tmp/manifest.yaml"
    ));
}

#[test]
fn response_contains_failure_detects_command_failed_text() {
    assert!(response_contains_failure("Command failed with exit code 1"));
}

#[test]
fn response_contains_failure_detects_apply_failed() {
    assert!(response_contains_failure(
        "apply failed for namespace default"
    ));
}

#[test]
fn response_contains_failure_detects_validation_failed() {
    assert!(response_contains_failure(
        "validation failed: MeshHTTPRoute is invalid"
    ));
}

#[test]
fn response_contains_failure_ignores_clean_output() {
    assert!(!response_contains_failure(
        "Successfully applied 3 manifests"
    ));
}

#[test]
fn response_contains_failure_empty_string() {
    assert!(!response_contains_failure(""));
}

// -- check_bug_found_gate --

#[test]
fn check_bug_found_gate_blocks_during_execution() {
    let state = base_state(RunnerPhase::Execution);
    let ctx = stub_context_with_state_and_response(
        Some(state),
        Some("ERROR [KSRCLI004] command failed: harness apply"),
    );
    let result = check_bug_found_gate(&ctx, "apply");
    assert!(result.is_some());
    let hook_result = result.unwrap();
    assert_eq!(hook_result.code, "KSR016");
}

#[test]
fn check_bug_found_gate_blocks_during_closeout() {
    let state = base_state(RunnerPhase::Closeout);
    let ctx = stub_context_with_state_and_response(
        Some(state),
        Some("ERROR [KSRCLI004] command failed: harness capture"),
    );
    let result = check_bug_found_gate(&ctx, "capture");
    assert!(result.is_some());
}

#[test]
fn check_bug_found_gate_skips_during_bootstrap() {
    let state = base_state(RunnerPhase::Bootstrap);
    let ctx = stub_context_with_state_and_response(
        Some(state),
        Some("ERROR [KSRCLI004] command failed: harness setup kuma cluster"),
    );
    assert!(check_bug_found_gate(&ctx, "cluster").is_none());
}

#[test]
fn check_bug_found_gate_skips_during_preflight() {
    let state = base_state(RunnerPhase::Preflight);
    let ctx = stub_context_with_state_and_response(
        Some(state),
        Some("ERROR [KSRCLI004] command failed: harness preflight"),
    );
    assert!(check_bug_found_gate(&ctx, "preflight").is_none());
}

#[test]
fn check_bug_found_gate_skips_during_triage() {
    let state = base_state(RunnerPhase::Triage);
    let ctx = stub_context_with_state_and_response(
        Some(state),
        Some("ERROR [KSRCLI004] command failed: harness apply"),
    );
    assert!(check_bug_found_gate(&ctx, "apply").is_none());
}

#[test]
fn check_bug_found_gate_skips_when_failure_already_set() {
    let mut state = base_state(RunnerPhase::Execution);
    state.failure = Some(FailureState {
        kind: FailureKind::Manifest,
        suite_target: None,
        message: None,
    });
    let ctx = stub_context_with_state_and_response(
        Some(state),
        Some("ERROR [KSRCLI004] command failed: harness apply"),
    );
    assert!(check_bug_found_gate(&ctx, "apply").is_none());
}

#[test]
fn check_bug_found_gate_skips_when_no_state() {
    let ctx = stub_context_with_state_and_response(
        None,
        Some("ERROR [KSRCLI004] command failed: harness apply"),
    );
    assert!(check_bug_found_gate(&ctx, "apply").is_none());
}

#[test]
fn check_bug_found_gate_skips_when_no_failure_in_response() {
    let state = base_state(RunnerPhase::Execution);
    let ctx =
        stub_context_with_state_and_response(Some(state), Some("Successfully applied 3 manifests"));
    assert!(check_bug_found_gate(&ctx, "apply").is_none());
}

#[test]
fn check_bug_found_gate_skips_when_response_empty() {
    let state = base_state(RunnerPhase::Execution);
    let ctx = stub_context_with_state_and_response(Some(state), None);
    assert!(check_bug_found_gate(&ctx, "apply").is_none());
}

// -- check_preflight_gate --

#[test]
fn preflight_gate_blocks_apply_during_bootstrap() {
    let state = base_state(RunnerPhase::Bootstrap);
    let ctx = stub_context_with_state_and_response(Some(state), None);
    let result = check_preflight_gate(&ctx, "apply");
    assert!(result.is_some());
    let hook_result = result.unwrap();
    assert_eq!(hook_result.code, "KSR014");
    assert!(hook_result.message.contains("preflight"));
}

#[test]
fn preflight_gate_blocks_apply_during_preflight_pending() {
    let state = base_state(RunnerPhase::Preflight);
    let ctx = stub_context_with_state_and_response(Some(state), None);
    let result = check_preflight_gate(&ctx, "apply");
    assert!(result.is_some());
}

#[test]
fn preflight_gate_blocks_apply_during_preflight_running() {
    let mut state = base_state(RunnerPhase::Preflight);
    state.preflight.status = PreflightStatus::Running;
    let ctx = stub_context_with_state_and_response(Some(state), None);
    let result = check_preflight_gate(&ctx, "apply");
    assert!(result.is_some());
}

#[test]
fn preflight_gate_allows_apply_after_preflight_complete() {
    let mut state = base_state(RunnerPhase::Preflight);
    state.preflight.status = PreflightStatus::Complete;
    let ctx = stub_context_with_state_and_response(Some(state), None);
    assert!(check_preflight_gate(&ctx, "apply").is_none());
}

#[test]
fn preflight_gate_allows_apply_during_execution() {
    let state = base_state(RunnerPhase::Execution);
    let ctx = stub_context_with_state_and_response(Some(state), None);
    assert!(check_preflight_gate(&ctx, "apply").is_none());
}

#[test]
fn preflight_gate_allows_apply_during_triage() {
    let state = base_state(RunnerPhase::Triage);
    let ctx = stub_context_with_state_and_response(Some(state), None);
    assert!(check_preflight_gate(&ctx, "apply").is_none());
}

#[test]
fn preflight_gate_skips_non_apply_subcommands() {
    let state = base_state(RunnerPhase::Bootstrap);
    let ctx = stub_context_with_state_and_response(Some(state), None);
    assert!(check_preflight_gate(&ctx, "cluster").is_none());
    assert!(check_preflight_gate(&ctx, "preflight").is_none());
    assert!(check_preflight_gate(&ctx, "capture").is_none());
}

#[test]
fn preflight_gate_skips_when_no_state() {
    let ctx = stub_context_with_state_and_response(None, None);
    assert!(check_preflight_gate(&ctx, "apply").is_none());
}

/// Build a minimal `HookContext` with the given runner state and response.
fn stub_context_with_state_and_response(
    runner_state: Option<RunnerWorkflowState>,
    response: Option<&str>,
) -> HookContext {
    let payload = HookEnvelopePayload {
        tool_name: "Bash".to_string(),
        tool_response: response.map_or(serde_json::Value::Null, |text| {
            serde_json::json!({
                "stdout": text,
                "stderr": "",
                "exit_code": 1,
            })
        }),
        ..HookEnvelopePayload::default()
    };

    let mut context = HookContext::from_test_envelope("suite:run", payload);
    context.runner_state = runner_state;
    context
}
