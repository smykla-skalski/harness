use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::workspace::project_context_dir;

use super::claude::{last_activity_from_log, parse_common_jsonl};
use super::event::ConversationEvent;
use super::signal::{Signal, SignalAck};
use super::{AgentRuntime, HookIntegrationPoint};

pub struct GeminiRuntime;

const HOOK_POINTS: &[HookIntegrationPoint] = &[HookIntegrationPoint {
    name: "BeforeTool",
    typical_latency_seconds: 5,
    supports_context_injection: true,
}];

impl AgentRuntime for GeminiRuntime {
    fn name(&self) -> &'static str {
        "gemini"
    }

    fn effort_env(&self, level: &str) -> Vec<(String, String)> {
        // Gemini exposes thinking via `thinking_config.thinking_budget` in
        // the API; the `gemini` CLI does not yet take a flag, so mirror
        // Claude's pattern and publish harness-prefixed env vars for wrapper
        // scripts. Budget caps: 0 disables, 2.5-Flash tops out ~8192, Pro ~24576.
        let tokens = match level {
            "off" => 0,
            "low" => 4_096,
            "medium" => 16_384,
            "high" => 24_576,
            _ => return Vec::new(),
        };
        vec![
            ("HARNESS_GEMINI_THINKING_LEVEL".into(), level.into()),
            (
                "HARNESS_GEMINI_THINKING_BUDGET_TOKENS".into(),
                tokens.to_string(),
            ),
        ]
    }

    fn discover_native_log(
        &self,
        session_id: &str,
        project_dir: &Path,
    ) -> Result<Option<PathBuf>, CliError> {
        let path = project_context_dir(project_dir)
            .join("agents/sessions/gemini")
            .join(session_id)
            .join("raw.jsonl");
        Ok(path.is_file().then_some(path))
    }

    fn parse_log_entry(&self, raw_line: &str) -> Option<ConversationEvent> {
        parse_common_jsonl(raw_line, "gemini")
    }

    fn signal_dir(&self, project_dir: &Path, session_id: &str) -> PathBuf {
        project_context_dir(project_dir)
            .join("agents/signals/gemini")
            .join(session_id)
    }

    fn write_signal(
        &self,
        project_dir: &Path,
        session_id: &str,
        signal: &Signal,
    ) -> Result<PathBuf, CliError> {
        super::signal::write_signal_file(&self.signal_dir(project_dir, session_id), signal)
    }

    fn read_acknowledgments(
        &self,
        project_dir: &Path,
        session_id: &str,
    ) -> Result<Vec<SignalAck>, CliError> {
        super::signal::read_acknowledgments(&self.signal_dir(project_dir, session_id))
    }

    fn last_activity(
        &self,
        project_dir: &Path,
        session_id: &str,
    ) -> Result<Option<String>, CliError> {
        last_activity_from_log(self, session_id, project_dir)
    }

    fn hook_integration_points(&self) -> &[HookIntegrationPoint] {
        HOOK_POINTS
    }

    fn initial_prompt_delivery(&self) -> super::InitialPromptDelivery {
        super::InitialPromptDelivery::CliFlag("--prompt-interactive")
    }
}
