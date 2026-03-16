use serde_json::json;

use crate::hook::{Decision, HookResult};

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

fn render_pre_tool_use_output(result: &HookResult) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    let message = render_hook_message(result);
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }
    }))
    .expect("hand-built JSON serializes")
}

fn render_blocking_hook_output(result: &HookResult) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    let message = render_hook_message(result);
    if result.decision == Decision::Deny {
        serde_json::to_string(&json!({"decision": "block", "reason": message}))
            .expect("hand-built JSON serializes")
    } else {
        serde_json::to_string(&json!({"systemMessage": message}))
            .expect("hand-built JSON serializes")
    }
}

fn render_post_tool_use_output(result: &HookResult, event_name: &str) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    let message = render_hook_message(result);
    let mut payload = json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": message,
        }
    });
    if result.decision == Decision::Deny {
        payload["decision"] = json!("block");
        payload["reason"] = json!(message);
    }
    serde_json::to_string(&payload).expect("hand-built JSON serializes")
}

fn render_additional_context_output(result: &HookResult, event_name: &str) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": render_hook_message(result),
        }
    }))
    .expect("hand-built JSON serializes")
}

/// Transform a `HookResult` into the native Claude Code hook output format for
/// the given hook type.
#[must_use]
pub fn render_hook_output(hook_type: HookType, result: &HookResult) -> String {
    if result.decision == Decision::Allow && result.code.is_empty() {
        return String::new();
    }

    match hook_type {
        HookType::PreToolUse => render_pre_tool_use_output(result),
        HookType::PostToolUse => render_post_tool_use_output(result, "PostToolUse"),
        HookType::PostToolUseFailure => render_post_tool_use_output(result, "PostToolUseFailure"),
        HookType::SubagentStart => render_additional_context_output(result, "SubagentStart"),
        HookType::SubagentStop => render_post_tool_use_output(result, "SubagentStop"),
        HookType::Blocking => render_blocking_hook_output(result),
    }
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
