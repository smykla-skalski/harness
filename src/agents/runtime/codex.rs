use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::workspace::project_context_dir;

use super::claude::{last_activity_from_log, parse_common_jsonl};
use super::event::ConversationEvent;
use super::signal::{Signal, SignalAck};
use super::{AgentRuntime, HookIntegrationPoint};

pub struct CodexRuntime;

const HOOK_POINTS: &[HookIntegrationPoint] = &[HookIntegrationPoint {
    name: "PreToolUse",
    typical_latency_seconds: 5,
    supports_context_injection: true,
}];

impl AgentRuntime for CodexRuntime {
    fn name(&self) -> &'static str {
        "codex"
    }

    fn discover_native_log(
        &self,
        session_id: &str,
        project_dir: &Path,
    ) -> Result<Option<PathBuf>, CliError> {
        let path = project_context_dir(project_dir)
            .join("agents/sessions/codex")
            .join(session_id)
            .join("raw.jsonl");
        Ok(path.is_file().then_some(path))
    }

    fn parse_log_entry(&self, raw_line: &str) -> Option<ConversationEvent> {
        parse_common_jsonl(raw_line, "codex")
    }

    fn signal_dir(&self, project_dir: &Path, session_id: &str) -> PathBuf {
        project_context_dir(project_dir)
            .join("agents/signals/codex")
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
}
