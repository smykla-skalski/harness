use super::*;
use crate::hooks::protocol::payloads::HookEnvelopePayload;

fn ctx(command: &str) -> GuardContext {
    GuardContext::from_test_envelope(
        "suite:run",
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

#[test]
fn allows_when_no_runner_state() {
    let guard = RunPhaseGuard;
    let c = ctx("harness run --phase verify --label test kubectl get pods");
    assert!(guard.check(&c).is_none());
}

#[test]
fn allows_plain_command() {
    let guard = RunPhaseGuard;
    let c = ctx("echo hello");
    assert!(guard.check(&c).is_none());
}
