use std::path::PathBuf;

use super::*;
use crate::hooks::application::GuardContext;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::hooks::protocol::result::NormalizedDecision;
use crate::run::workflow::{PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState};

fn base_ctx(skill: &str, command: &str) -> GuardContext {
    GuardContext::from_test_envelope(
        skill,
        HookEnvelopePayload {
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({ "command": command }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    )
}

fn active_runner_state() -> RunnerWorkflowState {
    RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-19T00:00:00Z".to_string(),
        transition_count: 1,
        last_event: Some("RunStarted".to_string()),
        history: Vec::new(),
    }
}

fn ctx(skill: &str, command: &str) -> GuardContext {
    let mut ctx = base_ctx(skill, command);
    if skill == "suite:run" {
        ctx.run_dir = Some(PathBuf::from("/tmp/harness-test-run"));
        ctx.runner_state = Some(active_runner_state());
    }
    ctx
}

#[test]
fn empty_chain_allows() {
    let chain = GuardChain::new(vec![]);
    let c = ctx("suite:run", "echo hello");
    let result = chain.evaluate(&c);
    assert_eq!(result.decision, NormalizedDecision::Allow);
}

#[test]
fn chain_stops_at_first_denial() {
    let chain = runner_bash_chain();
    let c = ctx("suite:run", "kubectl get pods");
    let result = chain.evaluate(&c);
    assert_eq!(result.decision, NormalizedDecision::Deny);
}

#[test]
fn chain_allows_safe_commands() {
    let chain = runner_bash_chain();
    let c = ctx("suite:run", "echo hello");
    let result = chain.evaluate(&c);
    assert_eq!(result.decision, NormalizedDecision::Allow);
}

#[test]
fn author_chain_denies_kubectl() {
    let chain = author_bash_chain();
    let c = ctx("suite:new", "kubectl get pods");
    let result = chain.evaluate(&c);
    assert_eq!(result.decision, NormalizedDecision::Deny);
}

#[test]
fn author_chain_allows_harness_command() {
    let chain = author_bash_chain();
    let c = ctx("suite:new", "harness authoring-show --kind session");
    let result = chain.evaluate(&c);
    assert_eq!(result.decision, NormalizedDecision::Allow);
}

#[test]
fn subshell_smuggling_caught_before_binary_check() {
    let chain = runner_bash_chain();
    let c = ctx("suite:run", "echo $(kubectl get pods)");
    let result = chain.evaluate(&c);
    assert_eq!(result.decision, NormalizedDecision::Deny);
    assert_eq!(result.code.as_deref(), Some("KSR017"));
}
