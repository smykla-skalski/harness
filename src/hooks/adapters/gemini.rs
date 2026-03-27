use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::errors::CliError;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::{NormalizedDecision, NormalizedHookResult};
use crate::kernel::tooling::ToolCategory;

pub struct GeminiAdapter;

#[derive(Serialize)]
struct GeminiConfig<'a> {
    hooks: BTreeMap<&'a str, Vec<GeminiEventRegistration<'a>>>,
}

#[derive(Serialize)]
struct GeminiEventRegistration<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    matcher: Option<&'a str>,
    hooks: Vec<GeminiCommandHook<'a>>,
}

#[derive(Serialize)]
struct GeminiCommandHook<'a> {
    #[serde(rename = "type")]
    hook_type: &'static str,
    command: &'a str,
    timeout: u64,
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

fn render_json<T: Serialize>(payload: &T) -> String {
    serde_json::to_string(payload).expect("typed hook JSON serializes")
}

impl AgentAdapter for GeminiAdapter {
    fn name(&self) -> &'static str {
        "gemini"
    }

    fn parse_input(&self, raw: &[u8]) -> Result<NormalizedHookContext, CliError> {
        let (payload, raw_value) = parse_process_payload(raw)?;
        Ok(payload_context(payload, raw_value, |tool_name| {
            self.normalize_tool(tool_name)
        }))
    }

    fn render_output(
        &self,
        result: &NormalizedHookResult,
        event: &NormalizedEvent,
    ) -> RenderedHookResponse {
        if result.decision == NormalizedDecision::Allow
            && result.additional_context.is_none()
            && result.updated_input.is_none()
        {
            return RenderedHookResponse {
                stdout: String::new(),
                exit_code: 0,
            };
        }

        let payload = build_gemini_payload(result, self.event_name(event).unwrap_or("unknown"));
        RenderedHookResponse {
            stdout: render_json(&payload),
            exit_code: 0,
        }
    }

    fn normalize_tool(&self, tool_name: &str) -> ToolCategory {
        match tool_name {
            "run_shell_command" => ToolCategory::Shell,
            "read_file" => ToolCategory::FileRead,
            "write_file" => ToolCategory::FileWrite,
            "replace" => ToolCategory::FileEdit,
            "search_files" | "list_dir" => ToolCategory::FileSearch,
            other => ToolCategory::Custom(other.to_string()),
        }
    }

    fn event_name(&self, event: &NormalizedEvent) -> Option<&str> {
        match event {
            NormalizedEvent::BeforeToolUse => Some("BeforeTool"),
            NormalizedEvent::AfterToolUse | NormalizedEvent::AfterToolUseFailure => {
                Some("AfterTool")
            }
            NormalizedEvent::SessionStart => Some("SessionStart"),
            NormalizedEvent::SessionEnd => Some("SessionEnd"),
            NormalizedEvent::AgentStart => Some("BeforeAgent"),
            NormalizedEvent::AgentStop => Some("AfterAgent"),
            NormalizedEvent::BeforeCompaction => Some("PreCompress"),
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
                .push(GeminiEventRegistration {
                    matcher: registration.matcher.as_deref(),
                    hooks: vec![GeminiCommandHook {
                        hook_type: "command",
                        command: &registration.command,
                        timeout: 5000,
                    }],
                });
        }
        serde_json::to_string_pretty(&GeminiConfig { hooks: events })
            .expect("typed hook JSON serializes")
    }
}

fn build_gemini_payload<'a>(
    result: &'a NormalizedHookResult,
    event_name: &'a str,
) -> GeminiOutput<'a> {
    let display_message = result.display_message();
    let denial = result.is_denial();
    let informational = matches!(
        result.decision,
        NormalizedDecision::Warn | NormalizedDecision::Info
    );

    GeminiOutput {
        decision: denial.then_some("deny"),
        reason: denial.then(|| display_message.clone()),
        system_message: informational.then_some(display_message),
        hook_specific_output: GeminiHookSpecificOutput {
            event_name,
            additional_context: result.additional_context.as_deref(),
            tool_input: result.updated_input.as_ref(),
        },
        continue_processing: result.halt_agent.then_some(false),
        suppress_output: result.suppress_output.then_some(true),
    }
}
