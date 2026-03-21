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
fn denies_direct_admin_endpoint() {
    let guard = AdminEndpointGuard;
    let c = ctx("curl localhost:9901/config_dump");
    assert!(guard.check(&c).is_some());
}

#[test]
fn denies_wget_admin_endpoint() {
    let guard = AdminEndpointGuard;
    let c = ctx("wget -qO- localhost:9901/clusters");
    assert!(guard.check(&c).is_some());
}

#[test]
fn allows_harness_envoy_capture() {
    let guard = AdminEndpointGuard;
    let c = ctx("harness envoy capture --phase verify --label config-dump \
         --namespace kuma-demo --workload deploy/demo-client \
         --admin-path /config_dump");
    assert!(guard.check(&c).is_none());
}

#[test]
fn allows_command_without_admin_hint() {
    let guard = AdminEndpointGuard;
    let c = ctx("echo hello");
    assert!(guard.check(&c).is_none());
}
