use serde_json::json;

use crate::hook::{Decision, HookResult};
use crate::hooks::result::{NormalizedDecision, NormalizedHookResult};

use super::HookType;

/// Format a hook result message with level prefix.
#[must_use]
pub fn render_hook_message(result: &HookResult) -> String {
    if result.code.is_empty() {
        return result.message.clone();
    }
    let level = match result.decision {
        Decision::Warn => "WARNING",
        Decision::Info => "INFO",
        Decision::Allow | Decision::Deny => "ERROR",
    };
    if result.message.is_empty() {
        format!("{level} [{}]", result.code)
    } else {
        format!("{level} [{}] {}", result.code, result.message)
    }
}

fn render_pre_tool_use_output_normalized(result: &NormalizedHookResult) -> String {
    if result.decision == NormalizedDecision::Allow {
        return String::new();
    }
    let message = result.display_message();
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }
    }))
    .expect("hand-built JSON serializes")
}

fn render_blocking_hook_output_normalized(result: &NormalizedHookResult) -> String {
    if result.decision == NormalizedDecision::Allow && result.additional_context.is_none() {
        return String::new();
    }
    let message = result.display_message();
    if result.decision == NormalizedDecision::Deny {
        serde_json::to_string(&json!({"decision": "block", "reason": message}))
            .expect("hand-built JSON serializes")
    } else {
        serde_json::to_string(&json!({"systemMessage": message}))
            .expect("hand-built JSON serializes")
    }
}

fn render_post_tool_use_output_normalized(
    result: &NormalizedHookResult,
    event_name: &str,
) -> String {
    if result.decision == NormalizedDecision::Allow
        && result.additional_context.is_none()
        && result.updated_input.is_none()
    {
        return String::new();
    }
    let message = result.display_message();
    let mut payload = json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
        }
    });
    if let Some(additional_context) = &result.additional_context {
        payload["hookSpecificOutput"]["additionalContext"] = json!(additional_context);
    } else if result.decision != NormalizedDecision::Allow {
        payload["hookSpecificOutput"]["additionalContext"] = json!(message);
    }
    if let Some(updated_input) = &result.updated_input {
        payload["hookSpecificOutput"]["toolInput"] = updated_input.clone();
    }
    if result.decision == NormalizedDecision::Deny {
        payload["decision"] = json!("block");
        payload["reason"] = json!(message);
    }
    serde_json::to_string(&payload).expect("hand-built JSON serializes")
}

fn render_additional_context_output_normalized(
    result: &NormalizedHookResult,
    event_name: &str,
) -> String {
    if result.decision == NormalizedDecision::Allow && result.additional_context.is_none() {
        return String::new();
    }
    let message = result
        .additional_context
        .clone()
        .unwrap_or_else(|| result.display_message());
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": message,
        }
    }))
    .expect("hand-built JSON serializes")
}

/// Transform a `NormalizedHookResult` into the native Claude Code hook output
/// format for the given hook type.
#[must_use]
pub fn render_normalized_hook_output(hook_type: HookType, result: &NormalizedHookResult) -> String {
    if result.decision == NormalizedDecision::Allow
        && result.additional_context.is_none()
        && result.updated_input.is_none()
    {
        return String::new();
    }

    match hook_type {
        HookType::PreToolUse => render_pre_tool_use_output_normalized(result),
        HookType::PostToolUse => render_post_tool_use_output_normalized(result, "PostToolUse"),
        HookType::PostToolUseFailure => {
            render_post_tool_use_output_normalized(result, "PostToolUseFailure")
        }
        HookType::SubagentStart => {
            render_additional_context_output_normalized(result, "SubagentStart")
        }
        HookType::SubagentStop => render_post_tool_use_output_normalized(result, "SubagentStop"),
        HookType::Blocking => render_blocking_hook_output_normalized(result),
    }
}

/// Transform a `HookResult` into the native Claude Code hook output format for
/// the given hook type.
#[must_use]
pub fn render_hook_output(hook_type: HookType, result: &HookResult) -> String {
    render_normalized_hook_output(
        hook_type,
        &NormalizedHookResult::from_hook_result(result.clone()),
    )
}

#[cfg(test)]
mod tests {
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
    fn blocking_deny_has_block_decision() {
        let r = HookResult::deny("KSR007", "incomplete");
        let output = render_hook_output(HookType::Blocking, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["decision"], "block");
        assert!(v["reason"].as_str().unwrap().contains("KSR007"));
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
    fn subagent_start_allow_with_additional_context_is_emitted() {
        let output = render_normalized_hook_output(
            HookType::SubagentStart,
            &NormalizedHookResult::allow().with_additional_context("save through authoring-save"),
        );
        let value: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(
            value["hookSpecificOutput"]["hookEventName"],
            "SubagentStart"
        );
        assert_eq!(
            value["hookSpecificOutput"]["additionalContext"],
            "save through authoring-save"
        );
    }

    #[test]
    fn hook_output_context_agent_routes_to_subagent_start() {
        let r = HookResult::warn("KSA006", "format");
        let output = render_hook_output(HookType::SubagentStart, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "SubagentStart");
    }

    #[test]
    fn hook_output_allow_is_always_empty() {
        for hook_type in [
            HookType::PreToolUse,
            HookType::Blocking,
            HookType::PostToolUse,
            HookType::PostToolUseFailure,
            HookType::SubagentStart,
            HookType::SubagentStop,
        ] {
            assert!(
                render_hook_output(hook_type, &HookResult::allow()).is_empty(),
                "allow should be empty for {hook_type:?}"
            );
        }
    }
}
