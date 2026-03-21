use super::*;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::run::context::RunContext;
use crate::run::workflow::{
    ManifestFixDecision, PreflightState, PreflightStatus, RunnerPhase, SuiteFixState,
};
use harness_testkit::RunDirBuilder;

#[test]
fn verify_suite_author_empty_amendments_denies() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    let path = tmp.path().parent().unwrap().join("amendments.md");
    fs::write(&path, "   \n").unwrap();
    let result = verify_suite_author(&[path.as_path()]);
    assert_eq!(result.decision, Decision::Deny);
    let _ = fs::remove_file(&path);
}

#[test]
fn verify_suite_author_nonempty_amendments_allows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("amendments.md");
    fs::write(&path, "real content here\n").unwrap();
    let result = verify_suite_author(&[path.as_path()]);
    assert_eq!(result.decision, Decision::Allow);
}

#[test]
fn verify_suite_runner_accumulates_suite_and_amendments_writes() {
    let tempdir = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = RunDirBuilder::new(tempdir.path(), "r01").build();
    let suite_manifest = suite_dir.join("suite.md");
    let amendments = suite_dir.join("amendments.md");
    fs::write(&amendments, "changes\n").unwrap();

    let payload = HookEnvelopePayload {
        tool_name: "Write".to_string(),
        tool_input: serde_json::json!({
            "file_paths": [
                suite_manifest.to_string_lossy(),
                amendments.to_string_lossy(),
            ],
        }),
        tool_response: serde_json::Value::Null,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    };
    let mut context = HookContext::from_test_envelope("suite:run", payload);
    context.run_dir = Some(run_dir.clone());
    context.run = Some(RunContext::from_run_dir(&run_dir).unwrap());
    context.runner_state = Some(RunnerWorkflowState {
        phase: RunnerPhase::Triage,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: false,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        }),
        updated_at: String::new(),
        transition_count: 0,
        last_event: None,
        history: Vec::new(),
    });

    let outcome = execute(&context).unwrap();
    let next_state = outcome.state_transitions().next().unwrap();
    let suite_fix = next_state.suite_fix.as_ref().unwrap();
    assert!(suite_fix.suite_written);
    assert!(suite_fix.amendments_written);
}
