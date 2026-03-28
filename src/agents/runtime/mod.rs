mod claude;
mod codex;
mod copilot;
pub mod event;
mod gemini;
pub mod liveness;
mod opencode;
pub mod signal;

use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;

use self::claude::ClaudeRuntime;
use self::codex::CodexRuntime;
use self::copilot::CopilotRuntime;
use self::event::ConversationEvent;
use self::gemini::GeminiRuntime;
use self::opencode::OpenCodeRuntime;
use self::signal::{Signal, SignalAck};

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

    /// Directory where signal files are written for this agent session.
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
