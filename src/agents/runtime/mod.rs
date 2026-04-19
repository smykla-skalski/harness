mod claude;
mod codex;
mod copilot;
pub mod event;
mod gemini;
pub mod liveness;
pub mod models;
mod opencode;
pub mod signal;
mod vibe;

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
use self::vibe::VibeRuntime;

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
#[expect(
    clippy::struct_excessive_bools,
    reason = "each bool is an independent capability flag in a serialized protocol type"
)]
pub struct RuntimeCapabilities {
    pub runtime: String,
    pub supports_native_transcript: bool,
    pub supports_signal_delivery: bool,
    pub supports_context_injection: bool,
    pub typical_signal_latency_seconds: u64,
    #[serde(default)]
    pub supports_readiness_signal: bool,
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

/// How the daemon delivers the initial join prompt to a terminal agent process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitialPromptDelivery {
    /// Append the prompt as a positional CLI argument (claude, codex, vibe).
    CliPositional,
    /// Append the prompt via a named CLI flag (gemini: `--prompt-interactive`).
    CliFlag(&'static str),
    /// Send the prompt via PTY input after a readiness callback (copilot, opencode).
    PtySend,
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

    /// Byte pattern emitted on the PTY when this runtime is ready to accept input.
    ///
    /// Returns `None` for runtimes where the startup marker is unknown; the
    /// caller falls back to a configurable timeout in that case.
    fn readiness_pattern(&self) -> Option<&'static str> {
        None
    }

    /// Whether this runtime fires a `SessionStart` hook that can signal
    /// readiness via the daemon callback. Runtimes without hooks (Vibe) return
    /// `false` and the daemon falls back to screen-text detection.
    fn supports_readiness_hook(&self) -> bool {
        true
    }

    /// How the daemon should deliver the initial join prompt to this runtime.
    ///
    /// Runtimes that accept an initial prompt via CLI argument avoid the PTY
    /// race entirely. Runtimes that don't support this fall back to PTY send
    /// after the `SessionStart` hook signals readiness.
    fn initial_prompt_delivery(&self) -> InitialPromptDelivery {
        InitialPromptDelivery::PtySend
    }

    /// CLI flag this runtime accepts to override the model for a session.
    ///
    /// Returns `Some("--model")` for runtimes that take a `--model <id>` pair
    /// (claude/codex/gemini/copilot/opencode/vibe). Runtimes that cannot be
    /// configured this way return `None` and the model selection is dropped
    /// with a warning at spawn time.
    fn model_flag(&self) -> Option<&'static str> {
        Some("--model")
    }

    /// CLI flag this runtime accepts to override the reasoning/thinking
    /// effort level for a session.
    ///
    /// Returns `Some("--reasoning-effort")` for runtimes whose CLI exposes
    /// effort directly (codex). Runtimes that configure effort via API body,
    /// config file, environment variable, or not at all return `None`.
    fn effort_flag(&self) -> Option<&'static str> {
        None
    }

    /// Environment variables this runtime consumes to receive the effort
    /// level when no CLI flag is available. Called once per spawn with the
    /// resolved effort level; the returned pairs are merged into the child
    /// process environment.
    ///
    /// Harness-owned variable names (prefixed `HARNESS_`) so downstream
    /// wrapper scripts can translate them to the provider-specific mechanism
    /// (Claude Code settings JSON, Gemini `thinking_config`, etc.).
    fn effort_env(&self, _level: &str) -> Vec<(String, String)> {
        Vec::new()
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
            supports_readiness_signal: self.readiness_pattern().is_some(),
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
    static VIBE: VibeRuntime = VibeRuntime;
    static OPENCODE: OpenCodeRuntime = OpenCodeRuntime;

    match agent {
        HookAgent::Claude => &CLAUDE,
        HookAgent::Codex => &CODEX,
        HookAgent::Gemini => &GEMINI,
        HookAgent::Copilot => &COPILOT,
        HookAgent::Vibe => &VIBE,
        HookAgent::OpenCode => &OPENCODE,
    }
}

/// Resolve a hook agent from a runtime name, including legacy aliases.
#[must_use]
pub fn hook_agent_for_runtime_name(name: &str) -> Option<HookAgent> {
    match name {
        "claude" => Some(HookAgent::Claude),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "copilot" => Some(HookAgent::Copilot),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

/// Resolve a runtime adapter from its stored string identifier.
#[must_use]
pub fn runtime_for_name(name: &str) -> Option<&'static dyn AgentRuntime> {
    hook_agent_for_runtime_name(name).map(runtime_for)
}

/// Render a user-invocable skill name using the runtime's command syntax.
#[must_use]
pub fn direct_skill_invocation(runtime_name: &str, skill_name: &str) -> String {
    format!("{}{skill_name}", direct_skill_prefix(runtime_name))
}

fn direct_skill_prefix(runtime_name: &str) -> &'static str {
    match hook_agent_for_runtime_name(runtime_name) {
        Some(HookAgent::Codex) => "$",
        Some(
            HookAgent::Claude
            | HookAgent::Gemini
            | HookAgent::Copilot
            | HookAgent::Vibe
            | HookAgent::OpenCode,
        )
        | None => "/",
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

#[cfg(test)]
mod tests {
    use super::{hook_agent_for_runtime_name, runtime_for_name};
    use crate::hooks::adapters::HookAgent;

    #[test]
    fn hook_agent_resolution_accepts_vibe_and_opencode() {
        assert_eq!(hook_agent_for_runtime_name("vibe"), Some(HookAgent::Vibe));
        assert_eq!(
            hook_agent_for_runtime_name("opencode"),
            Some(HookAgent::OpenCode)
        );
    }

    #[test]
    fn runtime_adapter_resolution_accepts_vibe_and_opencode() {
        assert_eq!(
            runtime_for_name("vibe").map(crate::agents::runtime::AgentRuntime::name),
            Some("vibe")
        );
        assert_eq!(
            runtime_for_name("opencode").map(crate::agents::runtime::AgentRuntime::name),
            Some("opencode")
        );
    }

    #[test]
    fn readiness_pattern_returns_valid_pattern_for_claude() {
        use super::runtime_for;
        let runtime = runtime_for(HookAgent::Claude);
        let pattern = runtime.readiness_pattern();
        assert!(
            pattern.is_some(),
            "claude runtime should provide a readiness pattern"
        );
        assert!(
            !pattern.unwrap().is_empty(),
            "claude readiness pattern should not be empty"
        );
    }

    #[test]
    fn readiness_pattern_returns_none_for_unknown_runtimes() {
        use super::runtime_for;
        // Runtimes without a known startup marker return None (timeout fallback).
        for agent in [
            HookAgent::Codex,
            HookAgent::Gemini,
            HookAgent::Copilot,
            HookAgent::OpenCode,
        ] {
            let runtime = runtime_for(agent);
            assert!(
                runtime.readiness_pattern().is_none(),
                "{} should return None for readiness_pattern",
                runtime.name()
            );
        }
    }

    #[test]
    fn runtime_capabilities_includes_readiness_signal_field() {
        use super::runtime_for;
        let claude_caps = runtime_for(HookAgent::Claude).capabilities();
        assert!(
            claude_caps.supports_readiness_signal,
            "claude capabilities should indicate readiness signal support"
        );

        let codex_caps = runtime_for(HookAgent::Codex).capabilities();
        assert!(
            !codex_caps.supports_readiness_signal,
            "codex capabilities should not indicate readiness signal support"
        );

        // Verify the field round-trips through serde.
        let json = serde_json::to_string(&claude_caps).expect("serialize");
        let deser: super::RuntimeCapabilities = serde_json::from_str(&json).expect("deserialize");
        assert!(deser.supports_readiness_signal);
    }

    #[test]
    fn initial_prompt_delivery_covers_all_runtimes() {
        use super::{InitialPromptDelivery, runtime_for};

        let cases = [
            (HookAgent::Claude, InitialPromptDelivery::CliPositional),
            (HookAgent::Codex, InitialPromptDelivery::PtySend),
            (
                HookAgent::Gemini,
                InitialPromptDelivery::CliFlag("--prompt-interactive"),
            ),
            (HookAgent::Copilot, InitialPromptDelivery::PtySend),
            (HookAgent::OpenCode, InitialPromptDelivery::PtySend),
            (HookAgent::Vibe, InitialPromptDelivery::CliPositional),
        ];
        for (agent, expected) in cases {
            let runtime = runtime_for(agent);
            assert_eq!(
                runtime.initial_prompt_delivery(),
                expected,
                "{} should return {:?}",
                runtime.name(),
                expected
            );
        }
    }
}
