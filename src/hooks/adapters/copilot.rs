use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, ProcessHookPayload, RenderedHookResponse, payload_context,
};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::kernel::tooling::ToolCategory;

pub struct CopilotAdapter;

#[derive(Serialize)]
struct CopilotConfig<'a> {
    version: u8,
    hooks: BTreeMap<&'a str, Vec<CopilotCommandHook<'a>>>,
}

#[derive(Serialize)]
struct CopilotCommandHook<'a> {
    #[serde(rename = "type")]
    hook_type: &'static str,
    bash: &'a str,
    cwd: &'static str,
    #[serde(rename = "timeoutSec")]
    timeout_sec: u64,
}

#[derive(Serialize)]
struct CopilotDenyOutput<'a> {
    #[serde(rename = "permissionDecision")]
    permission_decision: &'static str,
    #[serde(rename = "permissionDecisionReason")]
    permission_decision_reason: &'a str,
}

#[derive(Debug, Deserialize)]
struct CopilotHookPayload {
    #[serde(default)]
    cwd: Option<PathBuf>,
    #[serde(rename = "toolName", default)]
    tool_name: Option<String>,
    #[serde(rename = "toolArgs", default)]
    tool_args: Option<String>,
    #[serde(rename = "toolResult", default)]
    tool_result: Value,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(rename = "initialPrompt", default)]
    initial_prompt: Option<String>,
}

fn render_json<T: Serialize>(payload: &T) -> String {
    serde_json::to_string(payload).expect("typed hook JSON serializes")
}

impl AgentAdapter for CopilotAdapter {
    fn name(&self) -> &'static str {
        "copilot"
    }

    fn parse_input(&self, raw: &[u8]) -> Result<NormalizedHookContext, CliError> {
        let value: Value = serde_json::from_slice(raw).map_err(|error| {
            CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}"))
        })?;
        let payload: CopilotHookPayload =
            serde_json::from_value(value.clone()).map_err(|error| {
                CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}"))
            })?;
        let tool_input = payload
            .tool_args
            .as_deref()
            .and_then(|input| serde_json::from_str::<Value>(input).ok())
            .unwrap_or_else(|| Value::String(payload.tool_args.unwrap_or_default()));
        let process_payload = ProcessHookPayload {
            tool_name: payload.tool_name,
            tool_input,
            tool_response: payload.tool_result,
            last_assistant_message: None,
            transcript_path: None,
            session_id: None,
            cwd: payload.cwd,
            directory: None,
            hook_event_name: None,
            turn_id: None,
            agent_id: None,
            agent_type: Some("copilot".to_string()),
            prompt: payload.prompt.or(payload.initial_prompt),
            original_request_name: None,
        };
        Ok(payload_context(process_payload, value, |tool_name| {
            self.normalize_tool(tool_name)
        }))
    }

    fn render_output(
        &self,
        result: &NormalizedHookResult,
        _event: &NormalizedEvent,
    ) -> RenderedHookResponse {
        if !result.is_denial() {
            return RenderedHookResponse {
                stdout: String::new(),
                exit_code: 0,
            };
        }

        let reason = result.display_message();
        RenderedHookResponse {
            stdout: render_json(&CopilotDenyOutput {
                permission_decision: "deny",
                permission_decision_reason: &reason,
            }),
            exit_code: 0,
        }
    }

    fn normalize_tool(&self, tool_name: &str) -> ToolCategory {
        match tool_name {
            "bash" => ToolCategory::Shell,
            "view" | "read" => ToolCategory::FileRead,
            "edit" => ToolCategory::FileEdit,
            "create" | "write" => ToolCategory::FileWrite,
            "search" | "glob" => ToolCategory::FileSearch,
            other => ToolCategory::Custom(other.to_string()),
        }
    }

    fn event_name(&self, event: &NormalizedEvent) -> Option<&str> {
        match event {
            NormalizedEvent::UserPromptSubmit => Some("userPromptSubmitted"),
            NormalizedEvent::BeforeToolUse => Some("preToolUse"),
            NormalizedEvent::AfterToolUse => Some("postToolUse"),
            NormalizedEvent::AfterToolUseFailure => Some("errorOccurred"),
            NormalizedEvent::SessionStart => Some("sessionStart"),
            NormalizedEvent::SessionEnd | NormalizedEvent::AgentStop => Some("sessionEnd"),
            _ => None,
        }
    }

    fn generate_config(&self, hooks: &[HookRegistration]) -> String {
        let mut events = BTreeMap::new();
        for registration in hooks {
            let Some(event_name) = self.event_name(&registration.event) else {
                continue;
            };
            events
                .entry(event_name)
                .or_insert_with(Vec::new)
                .push(CopilotCommandHook {
                    hook_type: "command",
                    bash: &registration.command,
                    cwd: ".",
                    timeout_sec: 30,
                });
        }
        serde_json::to_string_pretty(&CopilotConfig {
            version: 1,
            hooks: events,
        })
        .expect("typed hook JSON serializes")
    }
}
