use super::*;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;

mod security_regressions;

fn ctx(skill: &str, command: &str) -> HookContext {
    HookContext::from_test_envelope(
        skill,
        HookEnvelopePayload {
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({
                "command": command,
            }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    )
}

#[test]
fn denies_direct_kubectl_for_suite_author() {
    let c = ctx("suite:create", "kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_rm_rf_suite_dir_for_suite_author() {
    let c = ctx(
        "suite:create",
        "rm -rf ~/.local/share/harness/suites/motb-compliance",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("mutate suite storage"));
}

#[test]
fn allows_harness_wrapper_for_suite_author() {
    let c = ctx("suite:create", "harness create-show --kind session");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_python_inline_in_suite_create() {
    let c = ctx(
        "suite:create",
        "harness create-show --kind coverage | python3 -c \"import json, sys; print(json.load(sys.stdin))\"",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("do not use python"));
}

#[test]
fn allows_empty_command() {
    let c = ctx("suite:create", "");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_inactive_skill() {
    let mut c = ctx("suite:create", "kubectl get pods");
    c.skill_active = false;
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

/// The retired suite:run skill still arrives from installed hook
/// registrations, so the guard must ignore it rather than fall through to a
/// create-shaped verdict.
#[test]
fn allows_retired_runner_skill_even_when_marked_active() {
    let mut c = ctx("suite:run", "kubectl get pods");
    c.skill_active = true;
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}
