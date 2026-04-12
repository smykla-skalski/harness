use serde::Serialize;
use serde_json::Value;

use crate::errors::CliError;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::{NormalizedDecision, NormalizedHookResult};
use crate::kernel::tooling::ToolCategory;

pub struct VibeAdapter;

#[derive(Serialize)]
struct VibeOutput<'a> {
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
struct VibeConfig<'a> {
    registrations: Vec<VibeRegistration<'a>>,
}

#[derive(Serialize)]
struct VibeRegistration<'a> {
    name: &'a str,
    event: &'a str,
    command: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    matcher: Option<&'a str>,
}

fn render_json<T: Serialize>(payload: &T) -> String {
    serde_json::to_string(payload).expect("typed hook JSON serializes")
}

impl AgentAdapter for VibeAdapter {
    fn name(&self) -> &'static str {
        "vibe"
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
        RenderedHookResponse {
            stdout: render_json(&VibeOutput {
                decision: match result.decision {
                    NormalizedDecision::Allow => "allow",
                    NormalizedDecision::Deny => "deny",
                    NormalizedDecision::Warn => "warn",
                    NormalizedDecision::Info => "info",
                },
                reason: result.reason.as_deref(),
                code: result.code.as_deref(),
                additional_context: result.additional_context.as_deref(),
                updated_input: result.updated_input.as_ref(),
                suppress_output: result.suppress_output,
                halt_agent: result.halt_agent,
            }),
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
                self.event_name(&registration.event)
                    .map(|event_name| VibeRegistration {
                        name: registration.name,
                        event: event_name,
                        command: &registration.command,
                        matcher: registration.matcher.as_deref(),
                    })
            })
            .collect::<Vec<_>>();
        serde_json::to_string_pretty(&VibeConfig { registrations })
            .expect("typed hook JSON serializes")
    }
}
