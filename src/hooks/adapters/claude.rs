use serde_json::json;

use crate::errors::CliError;
use crate::hooks::HookType;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::context::{NormalizedEvent, NormalizedHookContext, ToolCategory};
use crate::hooks::output;
use crate::hooks::result::NormalizedHookResult;

pub struct ClaudeCodeAdapter;

impl AgentAdapter for ClaudeCodeAdapter {
    fn name(&self) -> &'static str {
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
        RenderedHookResponse {
            stdout: output::render_normalized_hook_output(event_to_hook_type(event), result),
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
        use std::collections::BTreeMap;

        let mut events: BTreeMap<&str, Vec<serde_json::Value>> = BTreeMap::new();
        for registration in hooks {
            let Some(event_name) = self.event_name(&registration.event) else {
                continue;
            };
            let mut entry = serde_json::Map::new();
            if let Some(matcher) = &registration.matcher {
                entry.insert("matcher".to_string(), json!(matcher));
            }
            entry.insert(
                "hooks".to_string(),
                json!([{
                    "type": "command",
                    "command": registration.command,
                }]),
            );
            events
                .entry(event_name)
                .or_default()
                .push(serde_json::Value::Object(entry));
        }
        serde_json::to_string_pretty(&json!({ "hooks": events }))
            .expect("hand-built JSON serializes")
    }
}

fn event_to_hook_type(event: &NormalizedEvent) -> HookType {
    match event {
        NormalizedEvent::BeforeToolUse => HookType::PreToolUse,
        NormalizedEvent::AfterToolUseFailure => HookType::PostToolUseFailure,
        NormalizedEvent::SubagentStart => HookType::SubagentStart,
        NormalizedEvent::SubagentStop => HookType::SubagentStop,
        NormalizedEvent::AgentStop | NormalizedEvent::SessionEnd => HookType::Blocking,
        _ => HookType::PostToolUse,
    }
}
