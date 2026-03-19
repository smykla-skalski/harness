use serde_json::json;

use crate::errors::CliError;
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, RenderedHookResponse, parse_process_payload, payload_context,
};
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::{NormalizedDecision, NormalizedHookResult};
use crate::kernel::tooling::ToolCategory;

pub struct GeminiCliAdapter;

impl AgentAdapter for GeminiCliAdapter {
    fn name(&self) -> &'static str {
        "gemini-cli"
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
            stdout: serde_json::to_string(&payload).expect("hand-built JSON serializes"),
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
                    "timeout": 5000,
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

fn build_gemini_payload(result: &NormalizedHookResult, event_name: &str) -> serde_json::Value {
    let mut payload = gemini_decision_payload(result);
    if let Some(updated_input) = &result.updated_input {
        payload["hookSpecificOutput"]["tool_input"] = updated_input.clone();
    }
    if let Some(additional_context) = &result.additional_context {
        payload["hookSpecificOutput"]["additionalContext"] = json!(additional_context);
    }
    if result.halt_agent {
        payload["continue"] = json!(false);
    }
    if result.suppress_output {
        payload["suppressOutput"] = json!(true);
    }
    payload["hookSpecificOutput"]["eventName"] = json!(event_name);
    payload
}

fn gemini_decision_payload(result: &NormalizedHookResult) -> serde_json::Value {
    let mut payload = json!({});
    if result.is_denial() {
        payload["decision"] = json!("deny");
        payload["reason"] = json!(result.display_message());
    } else if matches!(
        result.decision,
        NormalizedDecision::Warn | NormalizedDecision::Info
    ) {
        payload["systemMessage"] = json!(result.display_message());
    }
    payload
}
