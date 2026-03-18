use serde_json::json;

use crate::errors::CliError;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext, ToolCategory};
use crate::hooks::protocol::result::{NormalizedDecision, NormalizedHookResult};

pub struct OpenCodeAdapter;

impl AgentAdapter for OpenCodeAdapter {
    fn name(&self) -> &'static str {
        "opencode"
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
        _event: &NormalizedEvent,
    ) -> RenderedHookResponse {
        let payload = json!({
            "decision": match result.decision {
                NormalizedDecision::Allow => "allow",
                NormalizedDecision::Deny => "deny",
                NormalizedDecision::Warn => "warn",
                NormalizedDecision::Info => "info",
            },
            "reason": result.reason,
            "code": result.code,
            "additionalContext": result.additional_context,
            "updatedInput": result.updated_input,
            "suppressOutput": result.suppress_output,
            "haltAgent": result.halt_agent,
        });
        RenderedHookResponse {
            stdout: serde_json::to_string(&payload).expect("hand-built JSON serializes"),
            exit_code: 0,
        }
    }

    fn normalize_tool(&self, tool_name: &str) -> ToolCategory {
        match tool_name {
            "bash" => ToolCategory::Shell,
            "read" => ToolCategory::FileRead,
            "write" => ToolCategory::FileWrite,
            "edit" => ToolCategory::FileEdit,
            other => ToolCategory::Custom(other.to_string()),
        }
    }

    fn event_name(&self, event: &NormalizedEvent) -> Option<&str> {
        match event {
            NormalizedEvent::BeforeToolUse => Some("tool.execute.before"),
            NormalizedEvent::AfterToolUse | NormalizedEvent::AfterToolUseFailure => {
                Some("tool.execute.after")
            }
            NormalizedEvent::AgentStop | NormalizedEvent::SessionEnd => Some("stop"),
            NormalizedEvent::SessionStart => Some("session.created"),
            _ => None,
        }
    }

    fn generate_config(&self, hooks: &[HookRegistration]) -> String {
        let registrations = hooks
            .iter()
            .filter_map(|registration| {
                self.event_name(&registration.event).map(|event_name| {
                    json!({
                        "name": registration.name,
                        "event": event_name,
                        "command": registration.command,
                        "matcher": registration.matcher,
                    })
                })
            })
            .collect::<Vec<_>>();
        serde_json::to_string_pretty(&json!({ "registrations": registrations }))
            .expect("hand-built JSON serializes")
    }
}
