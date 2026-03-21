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
fn denies_batched_tracked_harness_in_loop() {
    let guard = StructuralGuard;
    let c = ctx("for i in 01 02 03; do \
         harness apply --manifest \"g10/${i}.yaml\" --step \"g10-manifest-${i}\" || break; \
         done");
    assert!(guard.check(&c).is_some());
}

#[test]
fn denies_mixed_kuma_delete() {
    let guard = StructuralGuard;
    let c = ctx("harness record --phase cleanup --label cleanup-g04 -- \
         kubectl delete meshopentelemetrybackend otel-runtime \
         meshmetric metrics-runtime -n kuma-system");
    assert!(guard.check(&c).is_some());
}

#[test]
fn allows_single_kuma_delete() {
    let guard = StructuralGuard;
    let c = ctx("harness record --phase cleanup --label cleanup-g05 -- \
         kubectl delete meshopentelemetrybackend otel-e2e -n kuma-system");
    assert!(guard.check(&c).is_none());
}

#[test]
fn allows_plain_command() {
    let guard = StructuralGuard;
    let c = ctx("echo hello");
    assert!(guard.check(&c).is_none());
}
