use serde_json::json;

use crate::errors::CliError;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::context::{NormalizedEvent, NormalizedHookContext, ToolCategory};
use crate::hooks::output;
use crate::hooks::result::NormalizedHookResult;

pub struct ClaudeCodeAdapter;

impl AgentAdapter for ClaudeCodeAdapter {
    fn name(&self) -> &str {
        "claude-code"
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
        let stdout = output::render_normalized_hook_output(event_to_hook_type(event), result);
        RenderedHookResponse {
            stdout,
            exit_code: 0,
        }
    }

    fn normalize_tool(&self, tool_name: &str) -> ToolCategory {
        match tool_name {
            "Bash" => ToolCategory::Shell,
            "Read" => ToolCategory::FileRead,
            "Write" => ToolCategory::FileWrite,
            "Edit" => ToolCategory::FileEdit,
            "Glob" | "Grep" => ToolCategory::FileSearch,
            "Agent" => ToolCategory::Agent,
            "WebFetch" => ToolCategory::WebFetch,
            "WebSearch" => ToolCategory::WebSearch,
            other => ToolCategory::Custom(other.to_string()),
        }
    }

    fn event_name(&self, event: &NormalizedEvent) -> Option<&str> {
        match event {
            NormalizedEvent::BeforeToolUse => Some("PreToolUse"),
            NormalizedEvent::AfterToolUse => Some("PostToolUse"),
            NormalizedEvent::AfterToolUseFailure => Some("PostToolUseFailure"),
            NormalizedEvent::SessionStart => Some("SessionStart"),
            NormalizedEvent::SessionEnd => Some("SessionEnd"),
            NormalizedEvent::AgentStop => Some("Stop"),
            NormalizedEvent::SubagentStart => Some("SubagentStart"),
            NormalizedEvent::SubagentStop => Some("SubagentStop"),
            NormalizedEvent::BeforeCompaction => Some("PreCompact"),
            _ => None,
        }
    }

    fn generate_config(&self, hooks: &[HookRegistration]) -> String {
        let entries = hooks
            .iter()
            .filter_map(|registration| {
                self.event_name(&registration.event).map(|event_name| {
                    json!({
                        "event": event_name,
                        "matcher": registration.matcher,
                        "command": format!("harness hook --agent claude-code suite:run {}", registration.hook_name),
                    })
                })
            })
            .collect::<Vec<_>>();
        serde_json::to_string_pretty(&json!({ "hooks": entries }))
            .expect("hand-built JSON serializes")
    }
}

fn event_to_hook_type(event: &NormalizedEvent) -> crate::hooks::HookType {
    match event {
        NormalizedEvent::BeforeToolUse => crate::hooks::HookType::PreToolUse,
        NormalizedEvent::AfterToolUse => crate::hooks::HookType::PostToolUse,
        NormalizedEvent::AfterToolUseFailure => crate::hooks::HookType::PostToolUseFailure,
        NormalizedEvent::SubagentStart => crate::hooks::HookType::SubagentStart,
        NormalizedEvent::SubagentStop => crate::hooks::HookType::SubagentStop,
        NormalizedEvent::AgentStop | NormalizedEvent::SessionEnd => {
            crate::hooks::HookType::Blocking
        }
        _ => crate::hooks::HookType::PostToolUse,
    }
}
