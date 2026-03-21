use std::path::PathBuf;

use super::*;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
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

fn ctx_without_run(skill: &str, command: &str) -> GuardContext {
    base_ctx(skill, command)
}

#[test]
fn runner_denies_kubectl() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx("suite:run", "kubectl get pods");
    assert!(guard.check(&c).is_some());
}

#[test]
fn runner_allows_harness_run_with_kubectl() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx(
        "suite:run",
        "harness run record --phase verify --label pods -- kubectl get pods -o json",
    );
    assert!(guard.check(&c).is_none());
}

#[test]
fn runner_denies_python_inline() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx("suite:run", "python3 -c \"import json\"");
    assert!(guard.check(&c).is_some());
}

#[test]
fn runner_allows_python_version() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx("suite:run", "python3 --version");
    assert!(guard.check(&c).is_none());
}

#[test]
fn runner_allows_gh_without_tracked_run() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx_without_run("suite:run", "gh run view 12345");
    assert!(guard.check(&c).is_none());
}

#[test]
fn runner_allows_kubectl_without_tracked_run() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx_without_run("suite:run", "kubectl get pods");
    assert!(guard.check(&c).is_none());
}

#[test]
fn create_denies_kubectl() {
    let guard = DeniedBinaryGuard::create();
    let c = ctx("suite:create", "kubectl get pods");
    assert!(guard.check(&c).is_some());
}

#[test]
fn create_allows_harness() {
    let guard = DeniedBinaryGuard::create();
    let c = ctx("suite:create", "harness create-show --kind session");
    assert!(guard.check(&c).is_none());
}

#[test]
fn create_denies_rm_rf_suite_dir() {
    let guard = DeniedBinaryGuard::create();
    let c = ctx(
        "suite:create",
        "rm -rf ~/.local/share/harness/suites/motb-compliance",
    );
    let result = guard.check(&c);
    assert!(result.is_some());
}

#[test]
fn runner_allows_echo() {
    let guard = DeniedBinaryGuard::runner();
    let c = ctx("suite:run", "echo hello world");
    assert!(guard.check(&c).is_none());
}
