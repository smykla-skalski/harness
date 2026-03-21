use std::fs;

use harness_testkit::RunDirBuilder;

use super::*;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::run::context::RunContext;
use crate::run::workflow::{PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState};

fn ctx_audit(skill: &str) -> HookContext {
    HookContext::from_envelope(
        skill,
        HookEnvelopePayload {
            tool_name: String::new(),
            tool_input: serde_json::Value::Null,
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    )
}

#[test]
fn is_silent_suite_runner() {
    let context = ctx_audit("suite:run");
    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
    assert!(result.code.is_empty());
}

#[test]
fn is_silent_suite_author() {
    let context = ctx_audit("suite:create");
    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
    assert!(result.code.is_empty());
}

#[test]
fn allows_inactive_skill() {
    let mut context = ctx_audit("suite:run");
    context.skill_active = false;
    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
}

#[test]
fn writes_audit_entry_for_suite_run_hook() {
    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = RunDirBuilder::new(tempdir.path(), "r01").build_run_dir();
    let mut run_context = RunContext::from_run_dir(&run_dir).unwrap();
    let mut status = run_context.status.take().unwrap();
    status.next_planned_group = Some("g01".to_string());
    run_context.status = Some(status);

    let mut context = HookContext::from_test_envelope(
        "suite:run",
        HookEnvelopePayload {
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({
                "command": "harness record --phase verify --gid g01 -- echo hello",
            }),
            tool_response: serde_json::json!({
                "stdout": "hello\n",
                "stderr": "",
                "exit_code": 0,
            }),
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    );
    context.run_dir = Some(run_dir.clone());
    context.run = Some(run_context);
    context.runner_state = Some(RunnerWorkflowState {
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
    });

    let outcome = execute(&context).unwrap();
    let mut result = outcome.normalized_result();
    super::super::effects::apply_effects(&context, &mut result, outcome.effects()).unwrap();
    assert_eq!(result.to_hook_result().decision, Decision::Allow);

    let log_path = run_dir.join("audit-log.jsonl");
    let contents = fs::read_to_string(&log_path).unwrap();
    assert!(contents.contains("\"tool_name\":\"Bash\""));
    assert!(contents.contains("\"group_id\":\"g01\""));
    assert!(contents.contains("\"phase\":\"execution\""));
}

#[test]
fn allows_when_run_context_is_missing() {
    let context = HookContext::from_envelope(
        "suite:run",
        HookEnvelopePayload {
            tool_name: "Read".to_string(),
            tool_input: serde_json::json!({
                "file_path": "/tmp/test.txt",
            }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    );

    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
}
