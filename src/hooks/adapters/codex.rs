use serde_json::json;

use crate::errors::CliError;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::context::{NormalizedEvent, NormalizedHookContext, ToolCategory};
use crate::hooks::result::NormalizedHookResult;

pub struct CodexAdapter;

impl AgentAdapter for CodexAdapter {
    fn name(&self) -> &str {
        "codex"
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
        if !result.is_denial() {
            return RenderedHookResponse {
                stdout: String::new(),
                exit_code: 0,
            };
        }
        let payload = json!({
            "decision": "block",
            "reason": result.display_message(),
        });
        RenderedHookResponse {
            stdout: serde_json::to_string(&payload).expect("hand-built JSON serializes"),
            exit_code: 0,
        }
    }

    fn normalize_tool(&self, tool_name: &str) -> ToolCategory {
        ToolCategory::Custom(tool_name.to_string())
    }

    fn event_name(&self, event: &NormalizedEvent) -> Option<&str> {
        match event {
            NormalizedEvent::SessionStart => Some("SessionStart"),
            NormalizedEvent::AgentStop | NormalizedEvent::SessionEnd => Some("Stop"),
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
                        "command": format!("harness hook --agent codex suite:run {}", registration.hook_name),
                    })
                })
            })
            .collect::<Vec<_>>();
        serde_json::to_string_pretty(&json!({ "hooks": entries }))
            .expect("hand-built JSON serializes")
    }
}
