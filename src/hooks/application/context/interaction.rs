use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::kernel::command_intent::{ObservedCommand, ParsedCommand};
use crate::kernel::tooling::legacy_tool_context;

#[derive(Debug, Clone)]
enum ParsedCommandState {
    Missing,
    Parsed(ObservedCommand),
}

impl ParsedCommandState {
    fn from_command_text(command_text: Option<&str>) -> Self {
        let Some(command_text) = command_text else {
            return Self::Missing;
        };
        if command_text.trim().is_empty() {
            return Self::Missing;
        }
        Self::Parsed(ObservedCommand::parse(command_text))
    }

    fn as_result(&self) -> Result<Option<&ParsedCommand>, CliError> {
        match self {
            Self::Missing => Ok(None),
            Self::Parsed(observed) => observed.parsed().map_or_else(
                || {
                    let error = observed
                        .tokenization_error()
                        .unwrap_or("unknown parse error");
                    Err(CliErrorKind::hook_payload_invalid(format!(
                        "shell tokenization failed: {error}"
                    ))
                    .into())
                },
                |parsed| Ok(Some(parsed)),
            ),
        }
    }
}

#[derive(Debug, Clone)]
pub(super) struct HookInteraction {
    pub(super) tool_name: String,
    pub(super) tool_input: Value,
    pub(super) tool_response: Value,
    pub(super) last_assistant_message: Option<String>,
    pub(super) stop_hook_active: bool,
    parsed_command: ParsedCommandState,
}

impl HookInteraction {
    pub(super) fn from_normalized(normalized: &NormalizedHookContext) -> Self {
        let tool_name = normalized
            .tool
            .as_ref()
            .map_or_else(String::new, |tool| tool.original_name.clone());
        let tool_input = normalized
            .tool
            .as_ref()
            .map_or(Value::Null, |tool| tool.input_raw.clone());
        let tool_response = normalized
            .tool
            .as_ref()
            .and_then(|tool| tool.response.clone())
            .unwrap_or(Value::Null);
        let last_assistant_message = normalized
            .raw
            .as_value()
            .get("last_assistant_message")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or_else(|| {
                normalized
                    .agent
                    .as_ref()
                    .and_then(|agent| agent.response.clone())
            });
        let stop_hook_active = normalized
            .raw
            .as_value()
            .get("stop_hook_active")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let parsed_command = ParsedCommandState::from_command_text(
            tool_input.get("command").and_then(Value::as_str),
        );

        Self {
            tool_name,
            tool_input,
            tool_response,
            last_assistant_message,
            stop_hook_active,
            parsed_command,
        }
    }

    pub(super) fn parsed_command(&self) -> Result<Option<&ParsedCommand>, CliError> {
        self.parsed_command.as_result()
    }
}

pub(super) fn normalized_from_envelope(
    skill: &str,
    payload: HookEnvelopePayload,
) -> NormalizedHookContext {
    let raw = serde_json::to_value(&payload).unwrap_or(Value::Null);
    let tool_name = payload.tool_name;
    let input_raw = payload.tool_input;
    let response_raw = payload.tool_response;
    let tool = (!tool_name.is_empty()).then(|| {
        legacy_tool_context(
            &tool_name,
            input_raw,
            (!response_raw.is_null()).then_some(response_raw),
        )
    });

    NormalizedHookContext {
        event: NormalizedEvent::unspecified(),
        session: SessionContext {
            session_id: String::new(),
            cwd: None,
            transcript_path: payload.transcript_path,
        },
        tool,
        agent: payload.last_assistant_message.map(|response| AgentContext {
            agent_id: None,
            agent_type: None,
            prompt: None,
            response: Some(response),
        }),
        skill: SkillContext::from_skill_name(skill),
        raw: RawPayload::new(raw),
    }
}

pub(super) fn deserialize_value_list<T>(value: Option<&Value>) -> Vec<T>
where
    T: for<'de> serde::Deserialize<'de>,
{
    value
        .cloned()
        .and_then(|inner| serde_json::from_value(inner).ok())
        .unwrap_or_default()
}

pub(super) fn render_tool_response_text(tool_name: &str, tool_response: &Value) -> String {
    if tool_name == "Bash" {
        let stdout = tool_response
            .get("stdout")
            .and_then(Value::as_str)
            .unwrap_or("");
        let stderr = tool_response
            .get("stderr")
            .and_then(Value::as_str)
            .unwrap_or("");
        let exit_code = tool_response
            .get("exit_code")
            .or_else(|| tool_response.get("exitCode"))
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok())
            .unwrap_or_default();
        return format!(
            "exit code: {exit_code}\n--- STDOUT ---\n{stdout}\n--- STDERR ---\n{stderr}"
        );
    }

    match tool_response {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
    }
}
