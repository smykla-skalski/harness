use std::env;
use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{
    AgentAdapter, HookRegistration, ProcessHookPayload, RenderedHookResponse, payload_context,
};
use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::kernel::tooling::{ToolCategory, ToolContext, ToolInput};

pub struct CodexAdapter;

impl AgentAdapter for CodexAdapter {
    fn name(&self) -> &'static str {
        "codex"
    }

    fn parse_input(&self, raw: &[u8]) -> Result<NormalizedHookContext, CliError> {
        let raw_value = parse_json_value(raw)?;
        if is_notify_payload(&raw_value) {
            return notify_payload_context(raw_value);
        }
        let payload: ProcessHookPayload =
            serde_json::from_value(raw_value.clone()).map_err(|error| {
                CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}"))
            })?;
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
                    "timeout": 10,
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

const CODEX_TURN_TOOL_NAME: &str = "CodexTurn";
const CODEX_TURN_AGENT_TYPE: &str = "codex";
const CODEX_TURN_COMPLETE_TYPE: &str = "agent-turn-complete";

#[derive(Debug, Clone, Deserialize)]
struct CodexNotifyPayload {
    #[serde(rename = "type")]
    event_type: String,
    #[serde(rename = "thread-id")]
    thread_id: Option<String>,
    #[serde(rename = "turn-id")]
    turn_id: Option<String>,
    #[serde(default)]
    cwd: Option<PathBuf>,
    #[serde(rename = "input-messages", default)]
    input_messages: Vec<String>,
    #[serde(rename = "last-assistant-message")]
    last_assistant_message: Option<String>,
}

fn parse_json_value(raw: &[u8]) -> Result<Value, CliError> {
    serde_json::from_slice(raw).map_err(|error| {
        CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}")).into()
    })
}

fn is_notify_payload(value: &Value) -> bool {
    value.get("type").and_then(Value::as_str) == Some(CODEX_TURN_COMPLETE_TYPE)
}

fn notify_payload_context(raw_value: Value) -> Result<NormalizedHookContext, CliError> {
    let payload: CodexNotifyPayload =
        serde_json::from_value(raw_value.clone()).map_err(|error| {
            CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}"))
        })?;
    let cwd = payload
        .cwd
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let turn_id = payload.turn_id.clone();
    let prompt = (!payload.input_messages.is_empty()).then(|| payload.input_messages.join("\n\n"));
    let tool_input = json!({
        "type": payload.event_type,
        "cwd": cwd,
        "turn_id": turn_id,
        "input_messages": payload.input_messages,
    });
    let tool_response = json!({
        "last_assistant_message": payload.last_assistant_message,
        "turn_id": payload.turn_id,
    });

    Ok(NormalizedHookContext {
        event: NormalizedEvent::Notification,
        session: SessionContext {
            session_id: payload.thread_id.unwrap_or_default(),
            cwd,
            transcript_path: None,
        },
        tool: Some(ToolContext {
            category: ToolCategory::Custom(CODEX_TURN_TOOL_NAME.to_string()),
            original_name: CODEX_TURN_TOOL_NAME.to_string(),
            input: ToolInput::Other(tool_input.clone()),
            input_raw: tool_input,
            response: Some(tool_response),
        }),
        agent: Some(AgentContext {
            agent_id: turn_id,
            agent_type: Some(CODEX_TURN_AGENT_TYPE.to_string()),
            prompt,
            response: payload.last_assistant_message,
        }),
        skill: SkillContext::inactive(),
        raw: RawPayload::new(raw_value),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_notify_context(context: &NormalizedHookContext) {
        assert_eq!(context.event, NormalizedEvent::Notification);
        assert_eq!(context.session.session_id, "session-123");
        assert_eq!(context.session.cwd, PathBuf::from("/tmp/project"));
        let tool = context.tool.as_ref().expect("expected tool");
        assert_eq!(tool.original_name, CODEX_TURN_TOOL_NAME);
        assert_eq!(tool.input_raw["input_messages"][0], json!("run the suite"));
        let response = tool.response.as_ref().expect("expected response");
        assert_eq!(response["last_assistant_message"], json!("done"));
    }

    fn assert_notify_agent(context: &NormalizedHookContext) {
        let agent = context.agent.as_ref().expect("expected agent");
        assert_eq!(agent.agent_id.as_deref(), Some("turn-456"));
        assert_eq!(agent.agent_type.as_deref(), Some(CODEX_TURN_AGENT_TYPE));
        assert_eq!(agent.response.as_deref(), Some("done"));
    }

    #[test]
    fn parse_notify_payload_into_notification_context() {
        let adapter = CodexAdapter;
        let raw = serde_json::to_vec(&json!({
            "type": "agent-turn-complete",
            "thread-id": "session-123",
            "turn-id": "turn-456",
            "cwd": "/tmp/project",
            "input-messages": ["run the suite", "report failures"],
            "last-assistant-message": "done",
        }))
        .unwrap();

        let context = adapter.parse_input(&raw).unwrap();
        assert_notify_context(&context);
        assert_notify_agent(&context);
    }
}
