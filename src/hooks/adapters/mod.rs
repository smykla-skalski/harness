mod claude;
mod codex;
mod copilot;
mod gemini;
mod opencode;

use std::path::PathBuf;

use clap::ValueEnum;
use serde::Deserialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::kernel::tooling::{ToolCategory, ToolContext};

pub use claude::ClaudeAdapter;
pub use codex::CodexAdapter;
pub use copilot::CopilotAdapter;
pub use gemini::GeminiAdapter;
pub use opencode::OpenCodeAdapter;

/// Supported hook transports/adapters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum HookAgent {
    Claude,
    Copilot,
    Codex,
    Gemini,
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
    pub name: &'static str,
    pub event: NormalizedEvent,
    pub matcher: Option<String>,
    pub command: String,
}

/// Adapter trait for agent-specific parsing/rendering/config generation.
pub trait AgentAdapter: Send + Sync {
    fn name(&self) -> &'static str;
    /// Parse raw hook payload bytes into a normalized context.
    ///
    /// # Errors
    /// Returns `CliError` when the payload is malformed or unrecognized.
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
    #[serde(default, alias = "turn-id")]
    pub turn_id: Option<String>,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub agent_type: Option<String>,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub original_request_name: Option<String>,
}

pub(crate) fn parse_process_payload(raw: &[u8]) -> Result<(ProcessHookPayload, Value), CliError> {
    let value: Value = serde_json::from_slice(raw).map_err(|error| {
        CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}"))
    })?;
    let payload: ProcessHookPayload = serde_json::from_value(value.clone()).map_err(|error| {
        CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}"))
    })?;
    Ok((payload, value))
}

pub(crate) fn payload_event(payload: &ProcessHookPayload) -> NormalizedEvent {
    match payload.hook_event_name.as_deref() {
        Some("UserPromptSubmit" | "userPromptSubmitted") => NormalizedEvent::UserPromptSubmit,
        Some("PreToolUse" | "BeforeTool" | "BeforeToolUse" | "tool.execute.before") => {
            NormalizedEvent::BeforeToolUse
        }
        Some("PostToolUse" | "AfterTool" | "AfterToolUse" | "tool.execute.after") => {
            NormalizedEvent::AfterToolUse
        }
        Some("PostToolUseFailure" | "AfterToolUseFailure") => NormalizedEvent::AfterToolUseFailure,
        Some("SessionStart" | "session.created") => NormalizedEvent::SessionStart,
        Some("SessionEnd" | "session.deleted") => NormalizedEvent::SessionEnd,
        Some("BeforeAgent") => NormalizedEvent::AgentStart,
        Some("Stop" | "AfterAgent" | "stop") => NormalizedEvent::AgentStop,
        Some("SubagentStart") => NormalizedEvent::SubagentStart,
        Some("SubagentStop") => NormalizedEvent::SubagentStop,
        Some("PreCompact" | "PreCompress" | "session.compacting") => {
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
    let tool_name = payload
        .tool_name
        .as_deref()
        .or(payload.original_request_name.as_deref());
    let tool = tool_name.map(|name| {
        let category = normalize_tool(name);
        ToolContext::new(
            name,
            category,
            payload.tool_input.clone(),
            (!payload.tool_response.is_null()).then_some(payload.tool_response.clone()),
        )
    });

    NormalizedHookContext {
        event: payload_event(&payload),
        session: SessionContext {
            session_id: payload.session_id.unwrap_or_default(),
            cwd: payload.cwd.or(payload.directory),
            transcript_path: payload.transcript_path,
        },
        tool,
        agent: Some(AgentContext {
            agent_id: payload.agent_id.or(payload.turn_id),
            agent_type: payload.agent_type,
            prompt: payload.prompt,
            response: payload.last_assistant_message,
        }),
        skill: SkillContext::inactive(),
        raw: RawPayload::new(raw_value),
    }
}

#[must_use]
pub fn adapter_for(agent: HookAgent) -> &'static dyn AgentAdapter {
    static CLAUDE: ClaudeAdapter = ClaudeAdapter;
    static COPILOT: CopilotAdapter = CopilotAdapter;
    static CODEX: CodexAdapter = CodexAdapter;
    static GEMINI: GeminiAdapter = GeminiAdapter;
    static OPENCODE: OpenCodeAdapter = OpenCodeAdapter;

    match agent {
        HookAgent::Claude => &CLAUDE,
        HookAgent::Copilot => &COPILOT,
        HookAgent::Codex => &CODEX,
        HookAgent::Gemini => &GEMINI,
        HookAgent::OpenCode => &OPENCODE,
    }
}
