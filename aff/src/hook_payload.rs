use std::fmt;
use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;

use crate::hook_agent::HookAgent;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookEvent {
    BeforeToolUse,
    AfterToolUse,
    AfterToolUseFailure,
    SessionStart,
    SessionEnd,
    Notification,
    AgentSpecific(String),
    Unspecified,
}

impl fmt::Display for HookEvent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BeforeToolUse => formatter.write_str("PreToolUse"),
            Self::AfterToolUse => formatter.write_str("PostToolUse"),
            Self::AfterToolUseFailure => formatter.write_str("PostToolUseFailure"),
            Self::SessionStart => formatter.write_str("SessionStart"),
            Self::SessionEnd => formatter.write_str("SessionEnd"),
            Self::Notification => formatter.write_str("Notification"),
            Self::AgentSpecific(name) => formatter.write_str(name),
            Self::Unspecified => formatter.write_str("unspecified"),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct HookPayload {
    pub event: HookEvent,
    pub command_text: Option<String>,
    pub cwd: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct GenericHookPayload {
    #[serde(default)]
    tool_input: Value,
    #[serde(default)]
    cwd: Option<PathBuf>,
    #[serde(default)]
    directory: Option<PathBuf>,
    #[serde(default)]
    hook_event_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CopilotHookPayload {
    #[serde(default)]
    cwd: Option<PathBuf>,
    #[serde(rename = "toolArgs", default)]
    tool_args: Option<String>,
}

pub fn parse_hook_payload(agent: HookAgent, raw: &[u8]) -> Result<HookPayload, String> {
    match agent {
        HookAgent::Copilot => parse_copilot_payload(raw),
        HookAgent::Claude
        | HookAgent::Codex
        | HookAgent::Gemini
        | HookAgent::Vibe
        | HookAgent::OpenCode => parse_generic_payload(raw),
    }
}

fn parse_generic_payload(raw: &[u8]) -> Result<HookPayload, String> {
    let payload: GenericHookPayload =
        serde_json::from_slice(raw).map_err(|error| format!("invalid hook payload: {error}"))?;
    Ok(HookPayload {
        event: parse_event(payload.hook_event_name.as_deref()),
        command_text: extract_command_text(&payload.tool_input),
        cwd: payload.cwd.or(payload.directory),
    })
}

fn parse_copilot_payload(raw: &[u8]) -> Result<HookPayload, String> {
    let payload: CopilotHookPayload =
        serde_json::from_slice(raw).map_err(|error| format!("invalid hook payload: {error}"))?;
    let tool_input = parse_copilot_tool_args(payload.tool_args.as_deref())?;
    Ok(HookPayload {
        event: HookEvent::BeforeToolUse,
        command_text: extract_command_text(&tool_input),
        cwd: payload.cwd,
    })
}

fn parse_copilot_tool_args(tool_args: Option<&str>) -> Result<Value, String> {
    let Some(tool_args) = tool_args else {
        return Ok(Value::Null);
    };
    serde_json::from_str(tool_args)
        .map_err(|error| format!("invalid hook payload: invalid Copilot toolArgs JSON: {error}"))
}

fn parse_event(event_name: Option<&str>) -> HookEvent {
    match event_name {
        Some("PreToolUse" | "BeforeTool" | "BeforeToolUse" | "tool.execute.before") => {
            HookEvent::BeforeToolUse
        }
        Some("PostToolUse" | "AfterTool" | "AfterToolUse" | "tool.execute.after") => {
            HookEvent::AfterToolUse
        }
        Some("PostToolUseFailure" | "AfterToolUseFailure") => HookEvent::AfterToolUseFailure,
        Some("SessionStart" | "session.created") => HookEvent::SessionStart,
        Some("SessionEnd" | "session.deleted") => HookEvent::SessionEnd,
        Some("Notification") => HookEvent::Notification,
        Some(other) => HookEvent::AgentSpecific(other.to_string()),
        None => HookEvent::Unspecified,
    }
}

fn extract_command_text(tool_input: &Value) -> Option<String> {
    match tool_input {
        Value::Object(map) => map
            .get("command")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|command| !command.is_empty())
            .map(ToString::to_string),
        Value::String(command) => {
            let trimmed = command.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }
        _ => None,
    }
}
