mod claude;
mod codex;
mod copilot;
pub mod event;
mod gemini;
pub mod liveness;
mod opencode;
pub mod signal;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;

use self::claude::ClaudeRuntime;
use self::codex::CodexRuntime;
use self::copilot::CopilotRuntime;
use self::event::ConversationEvent;
use self::gemini::GeminiRuntime;
use self::opencode::OpenCodeRuntime;
use self::signal::{Signal, SignalAck};

pub(crate) use self::claude::parse_common_jsonl as parse_canonical_conversation_line;

/// Describes when during an agent's tool-use cycle signals can be intercepted.
#[derive(Debug, Clone)]
pub struct HookIntegrationPoint {
    /// Human-readable name of the integration point.
    pub name: &'static str,
    /// Typical latency before signal pickup in seconds.
    pub typical_latency_seconds: u64,
    /// Whether this point can inject context into the agent.
    pub supports_context_injection: bool,
}

/// Serializable runtime capability metadata exposed to session state and the daemon.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeCapabilities {
    pub runtime: String,
    pub supports_native_transcript: bool,
    pub supports_signal_delivery: bool,
    pub supports_context_injection: bool,
    pub typical_signal_latency_seconds: u64,
    #[serde(default)]
    pub hook_points: Vec<HookIntegrationDescriptor>,
}

/// One user-visible hook interception point for signal pickup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HookIntegrationDescriptor {
    pub name: String,
    pub typical_latency_seconds: u64,
    pub supports_context_injection: bool,
}

/// Per-agent runtime adapter for session-level concerns: log discovery,
/// conversation parsing, signal delivery, and liveness detection.
pub trait AgentRuntime: Send + Sync {
    /// Agent identifier matching `HookAgent` naming.
    fn name(&self) -> &'static str;

    /// Discover the native conversation log path for a session.
    ///
    /// Returns `None` when the runtime has no local transcript.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures.
    fn discover_native_log(
        &self,
        session_id: &str,
        project_dir: &Path,
    ) -> Result<Option<PathBuf>, CliError>;

    /// Parse a single raw JSONL line into a `ConversationEvent`.
    fn parse_log_entry(&self, raw_line: &str) -> Option<ConversationEvent>;

    /// Directory where signal files are written for this agent runtime session.
    fn signal_dir(&self, project_dir: &Path, session_id: &str) -> PathBuf;

    /// Write a signal file that the agent picks up on its next hook cycle.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures.
    fn write_signal(
        &self,
        project_dir: &Path,
        session_id: &str,
        signal: &Signal,
    ) -> Result<PathBuf, CliError>;

    /// Check for and consume pending acknowledgment files.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures.
    fn read_acknowledgments(
        &self,
        project_dir: &Path,
        session_id: &str,
    ) -> Result<Vec<SignalAck>, CliError>;

    /// Timestamp of the last observed activity, or `None` if unknown.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures.
    fn last_activity(
        &self,
        project_dir: &Path,
        session_id: &str,
    ) -> Result<Option<String>, CliError>;

    /// Hook integration points available for this runtime.
    fn hook_integration_points(&self) -> &[HookIntegrationPoint];

    /// Whether this runtime can produce a parseable native transcript.
    fn supports_native_transcript(&self) -> bool {
        true
    }

    /// Serializable capability snapshot for UI and daemon clients.
    fn capabilities(&self) -> RuntimeCapabilities {
        let hook_points: Vec<HookIntegrationDescriptor> = self
            .hook_integration_points()
            .iter()
            .map(|point| HookIntegrationDescriptor {
                name: point.name.to_string(),
                typical_latency_seconds: point.typical_latency_seconds,
                supports_context_injection: point.supports_context_injection,
            })
            .collect();
        let typical_signal_latency_seconds = hook_points
            .iter()
            .map(|point| point.typical_latency_seconds)
            .min()
            .unwrap_or(0);
        let supports_context_injection = hook_points
            .iter()
            .any(|point| point.supports_context_injection);

        RuntimeCapabilities {
            runtime: self.name().to_string(),
            supports_native_transcript: self.supports_native_transcript(),
            supports_signal_delivery: true,
            supports_context_injection,
            typical_signal_latency_seconds,
            hook_points,
        }
    }
}

/// Return the runtime adapter for a given agent.
#[must_use]
pub fn runtime_for(agent: HookAgent) -> &'static dyn AgentRuntime {
    static CLAUDE: ClaudeRuntime = ClaudeRuntime;
    static CODEX: CodexRuntime = CodexRuntime;
    static GEMINI: GeminiRuntime = GeminiRuntime;
    static COPILOT: CopilotRuntime = CopilotRuntime;
    static OPENCODE: OpenCodeRuntime = OpenCodeRuntime;

    match agent {
        HookAgent::Claude => &CLAUDE,
        HookAgent::Codex => &CODEX,
        HookAgent::Gemini => &GEMINI,
        HookAgent::Copilot => &COPILOT,
        HookAgent::OpenCode => &OPENCODE,
    }
}

/// Resolve a runtime adapter from its stored string identifier.
#[must_use]
pub fn runtime_for_name(name: &str) -> Option<&'static dyn AgentRuntime> {
    match name {
        "claude" => Some(runtime_for(HookAgent::Claude)),
        "codex" => Some(runtime_for(HookAgent::Codex)),
        "gemini" => Some(runtime_for(HookAgent::Gemini)),
        "copilot" => Some(runtime_for(HookAgent::Copilot)),
        "opencode" => Some(runtime_for(HookAgent::OpenCode)),
        _ => None,
    }
}

/// Candidate session keys to inspect for signal delivery.
///
/// New signal delivery is keyed by the target agent's runtime session ID. The
/// orchestration session ID stays as a legacy fallback so older queued signals
/// remain visible until they are drained.
#[must_use]
pub fn signal_session_keys(
    orchestration_session_id: &str,
    agent_session_id: Option<&str>,
) -> Vec<String> {
    let mut keys = Vec::new();
    if let Some(agent_session_id) = agent_session_id.filter(|value| !value.trim().is_empty()) {
        keys.push(agent_session_id.to_string());
    }
    if keys
        .last()
        .is_none_or(|last| last.as_str() != orchestration_session_id)
    {
        keys.push(orchestration_session_id.to_string());
    }
    keys
}
