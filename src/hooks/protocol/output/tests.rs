use super::*;

#[test]
fn render_hook_message_deny() {
    let r = HookResult::deny("KSR005", "blocked");
    assert_eq!(render_hook_message(&r), "ERROR [KSR005] blocked");
}

#[test]
fn render_hook_message_warn() {
    let r = HookResult::warn("KSR006", "caution");
    assert_eq!(render_hook_message(&r), "WARNING [KSR006] caution");
}

#[test]
fn render_hook_message_info() {
    let r = HookResult::info("KSR012", "ok");
    assert_eq!(render_hook_message(&r), "INFO [KSR012] ok");
}

#[test]
fn render_hook_message_empty_code() {
    let r = HookResult {
        decision: Decision::Warn,
        code: String::new(),
        message: "just a message".to_string(),
    };
    assert_eq!(render_hook_message(&r), "just a message");
}

#[test]
fn render_hook_message_empty_message() {
    let r = HookResult {
        decision: Decision::Deny,
        code: "KSR005".to_string(),
        message: String::new(),
    };
    assert_eq!(render_hook_message(&r), "ERROR [KSR005]");
}

#[test]
fn pre_tool_use_allow_is_empty() {
    assert!(render_hook_output(HookType::PreToolUse, &HookResult::allow()).is_empty());
}

#[test]
fn pre_tool_use_deny_has_permission_decision() {
    let r = HookResult::deny("KSR005", "blocked");
    let output = render_hook_output(HookType::PreToolUse, &r);
    let v: serde_json::Value = serde_json::from_str(&output).unwrap();
    assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PreToolUse");
    assert_eq!(v["hookSpecificOutput"]["permissionDecision"], "deny");
    assert!(
        v["hookSpecificOutput"]["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("KSR005")
    );
}

#[test]
fn pre_tool_use_allow_with_additional_context_is_emitted() {
    let output = render_normalized_hook_output(
        HookType::PreToolUse,
        &NormalizedHookResult::allow().with_additional_context("deliver signal before tool"),
    );
    let value: serde_json::Value = serde_json::from_str(&output).unwrap();
    assert_eq!(value["hookSpecificOutput"]["hookEventName"], "PreToolUse");
    assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "allow");
    assert_eq!(
        value["hookSpecificOutput"]["additionalContext"],
        "deliver signal before tool"
    );
}

#[test]
fn pre_tool_use_allow_with_updated_input_is_emitted() {
    let mut result = NormalizedHookResult::allow();
    result.updated_input = Some(serde_json::json!({
        "command": "echo injected",
    }));

    let output = render_normalized_hook_output(HookType::PreToolUse, &result);
    let value: serde_json::Value = serde_json::from_str(&output).unwrap();
    assert_eq!(value["hookSpecificOutput"]["hookEventName"], "PreToolUse");
    assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "allow");
    assert_eq!(
        value["hookSpecificOutput"]["updatedInput"]["command"],
        "echo injected"
    );
}

#[test]
fn post_tool_use_deny_includes_block() {
    let r = HookResult::deny("KSR014", "phase");
    let output = render_hook_output(HookType::PostToolUse, &r);
    let v: serde_json::Value = serde_json::from_str(&output).unwrap();
    assert_eq!(v["decision"], "block");
    assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
}

#[test]
fn hook_output_allow_is_always_empty() {
    for hook_type in [
        HookType::PreToolUse,
        HookType::PostToolUse,
    ] {
        assert!(
            render_hook_output(hook_type, &HookResult::allow()).is_empty(),
            "allow should be empty for {hook_type:?}"
        );
    }
}
