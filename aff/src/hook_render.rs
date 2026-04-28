use serde::Serialize;
use serde_json::Value;

use crate::hook_agent::HookAgent;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookDecision {
    Allow,
    Deny,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HookResult {
    pub decision: HookDecision,
    pub reason: Option<String>,
    pub code: Option<String>,
    pub additional_context: Option<String>,
    pub updated_input: Option<Value>,
    pub suppress_output: bool,
    pub halt_agent: bool,
}

impl HookResult {
    #[must_use]
    pub fn deny(code: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            decision: HookDecision::Deny,
            reason: Some(reason.into()),
            code: Some(code.into()),
            additional_context: None,
            updated_input: None,
            suppress_output: false,
            halt_agent: false,
        }
    }

    #[must_use]
    pub fn display_message(&self) -> String {
        let message = self
            .additional_context
            .as_deref()
            .filter(|message| !message.is_empty())
            .or(self.reason.as_deref())
            .unwrap_or_default();
        let Some(code) = self.code.as_deref() else {
            return message.to_string();
        };
        if message.is_empty() {
            format!("ERROR [{code}]")
        } else {
            format!("ERROR [{code}] {message}")
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedHookResponse {
    pub stdout: String,
    pub exit_code: i32,
}

impl RenderedHookResponse {
    #[must_use]
    pub fn allow() -> Self {
        Self {
            stdout: String::new(),
            exit_code: 0,
        }
    }
}

#[derive(Serialize)]
struct ClaudePermissionOutput<'a> {
    #[serde(rename = "hookSpecificOutput")]
    hook_specific_output: ClaudePermissionSpecificOutput<'a>,
}

#[derive(Serialize)]
struct ClaudePermissionSpecificOutput<'a> {
    #[serde(rename = "hookEventName")]
    hook_event_name: &'static str,
    #[serde(rename = "permissionDecision")]
    permission_decision: &'static str,
    #[serde(
        rename = "permissionDecisionReason",
        skip_serializing_if = "Option::is_none"
    )]
    permission_decision_reason: Option<&'a str>,
    #[serde(rename = "additionalContext", skip_serializing_if = "Option::is_none")]
    additional_context: Option<&'a str>,
    #[serde(rename = "updatedInput", skip_serializing_if = "Option::is_none")]
    updated_input: Option<&'a Value>,
}

#[derive(Serialize)]
struct CodexDenyOutput<'a> {
    decision: &'static str,
    reason: &'a str,
}

#[derive(Serialize)]
struct CopilotDenyOutput<'a> {
    #[serde(rename = "permissionDecision")]
    permission_decision: &'static str,
    #[serde(rename = "permissionDecisionReason")]
    permission_decision_reason: &'a str,
}

#[derive(Serialize)]
struct GeminiOutput<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    decision: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    #[serde(rename = "systemMessage", skip_serializing_if = "Option::is_none")]
    system_message: Option<String>,
    #[serde(rename = "hookSpecificOutput")]
    hook_specific_output: GeminiHookSpecificOutput<'a>,
    #[serde(rename = "continue", skip_serializing_if = "Option::is_none")]
    continue_processing: Option<bool>,
    #[serde(rename = "suppressOutput", skip_serializing_if = "Option::is_none")]
    suppress_output: Option<bool>,
}

#[derive(Serialize)]
struct GeminiHookSpecificOutput<'a> {
    #[serde(rename = "eventName")]
    event_name: &'a str,
    #[serde(rename = "additionalContext", skip_serializing_if = "Option::is_none")]
    additional_context: Option<&'a str>,
    #[serde(rename = "tool_input", skip_serializing_if = "Option::is_none")]
    tool_input: Option<&'a Value>,
}

#[derive(Serialize)]
struct GenericRuntimeOutput<'a> {
    decision: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'a str>,
    #[serde(rename = "additionalContext", skip_serializing_if = "Option::is_none")]
    additional_context: Option<&'a str>,
    #[serde(rename = "updatedInput", skip_serializing_if = "Option::is_none")]
    updated_input: Option<&'a Value>,
    #[serde(rename = "suppressOutput")]
    suppress_output: bool,
    #[serde(rename = "haltAgent")]
    halt_agent: bool,
}

#[derive(Serialize)]
struct SessionStartOutput<'a> {
    #[serde(rename = "hookSpecificOutput")]
    hook_specific_output: SessionStartSpecificOutput<'a>,
}

#[derive(Serialize)]
struct SessionStartSpecificOutput<'a> {
    #[serde(rename = "hookEventName")]
    hook_event_name: &'static str,
    #[serde(rename = "additionalContext")]
    additional_context: &'a str,
}

pub fn render_pre_tool_use_output(agent: HookAgent, result: &HookResult) -> RenderedHookResponse {
    if result.decision == HookDecision::Allow
        && result.additional_context.is_none()
        && result.updated_input.is_none()
    {
        return RenderedHookResponse::allow();
    }

    let stdout = match agent {
        HookAgent::Claude => render_json(&ClaudePermissionOutput {
            hook_specific_output: ClaudePermissionSpecificOutput {
                hook_event_name: "PreToolUse",
                permission_decision: if result.decision == HookDecision::Allow {
                    "allow"
                } else {
                    "deny"
                },
                permission_decision_reason: Some(result.display_message().as_str()),
                additional_context: result.additional_context.as_deref(),
                updated_input: result.updated_input.as_ref(),
            },
        }),
        HookAgent::Codex => {
            let reason = result.display_message();
            render_json(&CodexDenyOutput {
                decision: "block",
                reason: &reason,
            })
        }
        HookAgent::Copilot => {
            let reason = result.display_message();
            render_json(&CopilotDenyOutput {
                permission_decision: "deny",
                permission_decision_reason: &reason,
            })
        }
        HookAgent::Gemini => render_json(&GeminiOutput {
            decision: (result.decision == HookDecision::Deny).then_some("deny"),
            reason: (result.decision == HookDecision::Deny).then(|| result.display_message()),
            system_message: None,
            hook_specific_output: GeminiHookSpecificOutput {
                event_name: "BeforeTool",
                additional_context: result.additional_context.as_deref(),
                tool_input: result.updated_input.as_ref(),
            },
            continue_processing: result.halt_agent.then_some(false),
            suppress_output: result.suppress_output.then_some(true),
        }),
        HookAgent::Vibe | HookAgent::OpenCode => render_json(&GenericRuntimeOutput {
            decision: if result.decision == HookDecision::Allow {
                "allow"
            } else {
                "deny"
            },
            reason: result.reason.as_deref(),
            code: result.code.as_deref(),
            additional_context: result.additional_context.as_deref(),
            updated_input: result.updated_input.as_ref(),
            suppress_output: result.suppress_output,
            halt_agent: result.halt_agent,
        }),
    };

    RenderedHookResponse {
        stdout,
        exit_code: 0,
    }
}

pub fn render_session_start_output(
    _agent: HookAgent,
    additional_context: &str,
) -> Result<String, String> {
    serde_json::to_string(&SessionStartOutput {
        hook_specific_output: SessionStartSpecificOutput {
            hook_event_name: "SessionStart",
            additional_context,
        },
    })
    .map_err(|error| format!("failed to encode session-start output: {error}"))
}

fn render_json<T: Serialize>(payload: &T) -> String {
    serde_json::to_string(payload).expect("typed hook JSON serializes")
}
