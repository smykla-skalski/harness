mod claude;
mod codex;
mod gemini;
pub mod opencode;

use std::collections::HashMap;
use std::env;
use std::path::PathBuf;

use clap::ValueEnum;
use serde::Deserialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::hooks::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
    ToolCategory, ToolContext, ToolInput,
};
use crate::hooks::result::NormalizedHookResult;

pub use claude::ClaudeCodeAdapter;
pub use codex::CodexAdapter;
pub use gemini::GeminiCliAdapter;
pub use opencode::OpenCodeAdapter;

/// Supported hook transports/adapters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum HookAgent {
    ClaudeCode,
    GeminiCli,
    Codex,
    OpenCode,
}

/// Adapter-rendered process response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedHookResponse {
    pub stdout: String,
    pub exit_code: i32,
}

/// One hook registration entry for agent-specific config generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookRegistration {
    pub hook_name: &'static str,
    pub event: NormalizedEvent,
    pub matcher: Option<String>,
}

/// Adapter trait for agent-specific parsing/rendering/config generation.
pub trait AgentAdapter: Send + Sync {
    fn name(&self) -> &str;
    fn parse_input(&self, raw: &[u8]) -> Result<NormalizedHookContext, CliError>;
    fn render_output(
        &self,
        result: &NormalizedHookResult,
        event: &NormalizedEvent,
    ) -> RenderedHookResponse;
    fn normalize_tool(&self, tool_name: &str) -> ToolCategory;
    fn event_name(&self, event: &NormalizedEvent) -> Option<&str>;
    fn generate_config(&self, hooks: &[HookRegistration]) -> String;
}

#[derive(Debug, Deserialize)]
pub(crate) struct ProcessHookPayload {
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_input: Value,
    #[serde(default)]
    pub tool_response: Value,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<PathBuf>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub directory: Option<PathBuf>,
    #[serde(default)]
    pub hook_event_name: Option<String>,
    #[serde(default)]
    pub stop_hook_active: bool,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_type: Option<String>,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub original_request_name: Option<String>,
    #[serde(flatten)]
    pub extra: HashMap<String, Value>,
}

pub(crate) fn parse_process_payload(raw: &[u8]) -> Result<(ProcessHookPayload, Value), CliError> {
    let value: Value = serde_json::from_slice(raw).map_err(|error| {
        CliErrorKind::hook_payload_invalid(cow!("invalid hook payload: {error}"))
    })?;
    let payload: ProcessHookPayload = serde_json::from_value(value.clone()).map_err(|error| {
        CliErrorKind::hook_payload_invalid(cow!("invalid hook payload: {error}"))
    })?;
    Ok((payload, value))
}

pub(crate) fn payload_event(payload: &ProcessHookPayload) -> NormalizedEvent {
    match payload.hook_event_name.as_deref() {
        Some("PreToolUse")
        | Some("BeforeTool")
        | Some("BeforeToolUse")
        | Some("tool.execute.before") => NormalizedEvent::BeforeToolUse,
        Some("PostToolUse")
        | Some("AfterTool")
        | Some("AfterToolUse")
        | Some("tool.execute.after") => NormalizedEvent::AfterToolUse,
        Some("PostToolUseFailure") | Some("AfterToolUseFailure") => {
            NormalizedEvent::AfterToolUseFailure
        }
        Some("SessionStart") | Some("session.created") => NormalizedEvent::SessionStart,
        Some("SessionEnd") | Some("session.deleted") => NormalizedEvent::SessionEnd,
        Some("BeforeAgent") => NormalizedEvent::AgentStart,
        Some("Stop") | Some("AfterAgent") | Some("stop") => NormalizedEvent::AgentStop,
        Some("SubagentStart") => NormalizedEvent::SubagentStart,
        Some("SubagentStop") => NormalizedEvent::SubagentStop,
        Some("PreCompact") | Some("PreCompress") | Some("session.compacting") => {
            NormalizedEvent::BeforeCompaction
        }
        Some("PostCompact") => NormalizedEvent::AfterCompaction,
        Some("Notification") => NormalizedEvent::Notification,
        Some(other) => NormalizedEvent::AgentSpecific(other.to_string()),
        None => NormalizedEvent::unspecified(),
    }
}

pub(crate) fn payload_context<F>(
    payload: ProcessHookPayload,
    raw_value: Value,
    normalize_tool: F,
) -> NormalizedHookContext
where
    F: Fn(&str) -> ToolCategory,
{
    let _stop_hook_active = payload.stop_hook_active;
    let _extra_field_count = payload.extra.len();
    let tool_name = payload
        .tool_name
        .as_deref()
        .or(payload.original_request_name.as_deref());
    let tool = tool_name.map(|name| {
        let category = normalize_tool(name);
        ToolContext {
            category: category.clone(),
            original_name: name.to_string(),
            input: normalize_tool_input(&category, &payload.tool_input),
            input_raw: payload.tool_input.clone(),
            response: (!payload.tool_response.is_null()).then_some(payload.tool_response.clone()),
        }
    });

    NormalizedHookContext {
        event: payload_event(&payload),
        session: SessionContext {
            session_id: payload.session_id.unwrap_or_default(),
            cwd: payload
                .cwd
                .or(payload.directory)
                .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from("."))),
            transcript_path: payload.transcript_path,
        },
        tool,
        agent: Some(AgentContext {
            agent_id: payload.agent_id,
            agent_type: payload.agent_type,
            prompt: payload.prompt,
            response: payload.last_assistant_message,
        }),
        skill: SkillContext::inactive(),
        raw: RawPayload::new(raw_value),
    }
}

fn normalize_tool_input(category: &ToolCategory, input: &Value) -> ToolInput {
    match category {
        ToolCategory::Shell => ToolInput::Shell {
            command: input
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            description: input
                .get("description")
                .and_then(Value::as_str)
                .map(ToString::to_string),
        },
        ToolCategory::FileRead => ToolInput::FileRead {
            path: PathBuf::from(
                input
                    .get("file_path")
                    .or_else(|| input.get("path"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
        },
        ToolCategory::FileWrite => ToolInput::FileWrite {
            path: PathBuf::from(
                input
                    .get("file_path")
                    .or_else(|| input.get("path"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
            content: input
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        },
        ToolCategory::FileEdit => ToolInput::FileEdit {
            path: PathBuf::from(
                input
                    .get("file_path")
                    .or_else(|| input.get("path"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
            old_text: input
                .get("old_text")
                .or_else(|| input.get("oldText"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            new_text: input
                .get("new_text")
                .or_else(|| input.get("newText"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        },
        ToolCategory::FileSearch => ToolInput::FileSearch {
            pattern: input
                .get("pattern")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            path: input.get("path").and_then(Value::as_str).map(PathBuf::from),
        },
        _ => ToolInput::Other(input.clone()),
    }
}

#[must_use]
pub fn adapter_for(agent: HookAgent) -> &'static dyn AgentAdapter {
    static CLAUDE: ClaudeCodeAdapter = ClaudeCodeAdapter;
    static GEMINI: GeminiCliAdapter = GeminiCliAdapter;
    static CODEX: CodexAdapter = CodexAdapter;
    static OPENCODE: OpenCodeAdapter = OpenCodeAdapter;

    match agent {
        HookAgent::ClaudeCode => &CLAUDE,
        HookAgent::GeminiCli => &GEMINI,
        HookAgent::Codex => &CODEX,
        HookAgent::OpenCode => &OPENCODE,
    }
}
