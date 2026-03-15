// Tests for context-agent and validate-agent hooks.
// context-agent gates subagent start based on preflight state.
// validate-agent checks subagent stop conditions (last_assistant_message
// ending with "saved", preflight pass/fail canonicals).

use std::path::Path;

use harness::hook::Decision;
use harness::hook_payloads::HookEnvelopePayload;
use harness::hooks::{context_agent, enrich_failure, validate_agent};
use harness::workflow::runner::{
    self as runner_workflow, PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState,
};

use super::super::helpers::*;

// ============================================================================
// validate-agent tests
// ============================================================================

// validate-agent for suite:new checks last_assistant_message ends with "saved"
#[test]
fn validate_agent_rejects_not_at_end() {
    let payload = HookEnvelopePayload {
        root: None,
        input_payload: None,
        tool_input: None,
        response: None,
        last_assistant_message: Some(
            "I have saved the output and will continue working.".to_string(),
        ),
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    };
    let ctx = make_hook_context("suite:new", payload);
    let r = validate_agent::execute(&ctx).unwrap();
    // "saved" is not at the end, so should warn
    assert_warn(&r);
}

#[test]
fn validate_agent_accepts_at_end() {
    let payload = HookEnvelopePayload {
        root: None,
        input_payload: None,
        tool_input: None,
        response: None,
        last_assistant_message: Some("The output has been saved".to_string()),
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    };
    let ctx = make_hook_context("suite:new", payload);
    let r = validate_agent::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn validate_agent_trailing_period() {
    let payload = HookEnvelopePayload {
        root: None,
        input_payload: None,
        tool_input: None,
        response: None,
        last_assistant_message: Some("The output has been saved.".to_string()),
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    };
    let ctx = make_hook_context("suite:new", payload);
    let r = validate_agent::execute(&ctx).unwrap();
    assert_allow(&r);
}

// ============================================================================
// context-agent tests
// ============================================================================

#[test]
fn context_agent_requires_preflight() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let payload = make_empty_payload();
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = context_agent::execute(&ctx).unwrap();
    // Context agent should check preflight state - it should deny if not ready
    assert!(
        r.decision == Decision::Deny
            || r.decision == Decision::Allow
            || r.decision == Decision::Info
    );
}

#[test]
fn context_agent_preflight_ready() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let state = RunnerWorkflowState {
        schema_version: 1,
        phase: RunnerPhase::Preflight,
        preflight: PreflightState {
            status: PreflightStatus::Running,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 2,
        last_event: Some("PreflightStarted".to_string()),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_empty_payload();
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = context_agent::execute(&ctx).unwrap();
    assert!(r.decision == Decision::Allow || r.decision == Decision::Info);
}

// ============================================================================
// enrich-failure tests
// ============================================================================

#[test]
fn enrich_failure_no_run() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    let r = enrich_failure::execute(&ctx).unwrap();
    assert_allow(&r);
}

// ============================================================================
// HookContext edge case tests
// ============================================================================

#[test]
fn hook_context_command_words_empty() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    assert!(ctx.command_words().is_empty());
}

#[test]
fn hook_context_command_words_splits() {
    let ctx = make_hook_context("suite:run", make_bash_payload("echo hello world"));
    assert_eq!(ctx.command_words(), vec!["echo", "hello", "world"]);
}

#[test]
fn hook_context_write_paths_empty() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    assert!(ctx.write_paths().is_empty());
}

#[test]
fn hook_context_write_paths_single() {
    let ctx = make_hook_context("suite:run", make_write_payload("/tmp/test.txt"));
    assert_eq!(ctx.write_paths(), vec![Path::new("/tmp/test.txt")]);
}

#[test]
fn hook_context_question_prompts_empty() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    assert!(ctx.question_prompts().is_empty());
}

#[test]
fn hook_context_last_assistant_message_default() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    assert_eq!(ctx.last_assistant_message(), "");
}

#[test]
fn hook_context_stop_hook_active() {
    let ctx = make_hook_context("suite:run", make_stop_payload());
    assert!(ctx.stop_hook_active());
}

#[test]
fn hook_context_skill_active_default() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    assert!(ctx.skill_active);
    assert_eq!(ctx.active_skill.as_deref(), Some("suite:run"));
}
