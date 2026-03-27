use std::collections::BTreeMap;

use serde::Serialize;

use crate::errors::CliError;
use crate::hooks::HookType;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::output;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::kernel::tooling::ToolCategory;

pub struct ClaudeAdapter;

#[derive(Serialize)]
struct ClaudeConfig<'a> {
    hooks: BTreeMap<&'a str, Vec<ClaudeEventRegistration<'a>>>,
}

#[derive(Serialize)]
struct ClaudeEventRegistration<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    matcher: Option<&'a str>,
    hooks: Vec<ClaudeCommandHook<'a>>,
}

#[derive(Serialize)]
struct ClaudeCommandHook<'a> {
    #[serde(rename = "type")]
    hook_type: &'static str,
    command: &'a str,
}

impl AgentAdapter for ClaudeAdapter {
    fn name(&self) -> &'static str {
        "claude"
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
            NormalizedEvent::Notification => Some("Notification"),
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
        let mut events = BTreeMap::new();
        for registration in hooks {
            let Some(event_name) = self.event_name(&registration.event) else {
                continue;
            };
            events
                .entry(event_name)
                .or_insert_with(Vec::new)
                .push(ClaudeEventRegistration {
                    matcher: registration.matcher.as_deref(),
                    hooks: vec![ClaudeCommandHook {
                        hook_type: "command",
                        command: &registration.command,
                    }],
                });
        }
        serde_json::to_string_pretty(&ClaudeConfig { hooks: events })
            .expect("typed hook JSON serializes")
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
