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
fn denies_kubectl_in_subshell() {
    let guard = SubshellGuard;
    let c = ctx("echo $(kubectl get pods)");
    let result = guard.check(&c);
    assert!(result.is_some());
    let result = result.unwrap();
    assert_eq!(result.code.as_deref(), Some("KSR017"));
}

#[test]
fn denies_docker_in_backtick() {
    let guard = SubshellGuard;
    let c = ctx("echo `docker ps`");
    let result = guard.check(&c);
    assert!(result.is_some());
}

#[test]
fn allows_safe_subshell() {
    let guard = SubshellGuard;
    let c = ctx("echo $(date +%Y-%m-%d)");
    assert!(guard.check(&c).is_none());
}

#[test]
fn allows_plain_command() {
    let guard = SubshellGuard;
    let c = ctx("echo hello");
    assert!(guard.check(&c).is_none());
}
