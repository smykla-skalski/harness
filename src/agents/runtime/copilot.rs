use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::workspace::project_context_dir;

use super::claude::last_activity_from_log;
use super::event::ConversationEvent;
use super::signal::{Signal, SignalAck};
use super::{AgentRuntime, HookIntegrationPoint};

pub struct CopilotRuntime;

const HOOK_POINTS: &[HookIntegrationPoint] = &[HookIntegrationPoint {
    name: "preToolUse",
    typical_latency_seconds: 5,
    supports_context_injection: false,
}];

impl AgentRuntime for CopilotRuntime {
    fn name(&self) -> &'static str {
        "copilot"
    }

    fn discover_native_log(
        &self,
        session_id: &str,
        project_dir: &Path,
    ) -> Result<Option<PathBuf>, CliError> {
        // Copilot has no local JSONL transcript; rely on harness ledger only.
        let path = project_context_dir(project_dir)
            .join("agents/sessions/copilot")
            .join(session_id)
            .join("raw.jsonl");
        Ok(path.is_file().then_some(path))
    }

    fn parse_log_entry(&self, _raw_line: &str) -> Option<ConversationEvent> {
        // Copilot log format is not directly parseable as common JSONL.
        None
    }

    fn signal_dir(&self, project_dir: &Path, session_id: &str) -> PathBuf {
        project_context_dir(project_dir)
            .join("agents/signals/copilot")
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

    fn supports_native_transcript(&self) -> bool {
        false
    }
}
