use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::agents::runtime::{AgentRuntime, InitialPromptDelivery, runtime_for_name};
use crate::daemon::agent_tui::{
    AgentTuiAttachState, AgentTuiProcess, AgentTuiSnapshot, AgentTuiStatus,
    deliver_deferred_prompts, snapshot_from_process, spawn_agent_tui_process,
};
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::errors::{CliError, CliErrorKind};

use super::core::{BridgeActiveTui, BridgeAgentTuiMetadata, BridgeSnapshotContext};
use super::helpers::stringify_metadata_map;
use super::server::BridgeServer;
use super::types::{AgentTuiStartSpec, BRIDGE_CAPABILITY_AGENT_TUI, BridgeCapability};

impl BridgeServer {
    pub(super) fn start_agent_tui(
        &self,
        spec: AgentTuiStartSpec,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if !self
            .capabilities()?
            .contains_key(BRIDGE_CAPABILITY_AGENT_TUI)
        {
            return Err(CliErrorKind::sandbox_feature_disabled(
                BridgeCapability::AgentTui.sandbox_feature(),
            )
            .into());
        }
        if self.active_tuis()?.contains_key(&spec.tui_id) {
            return Err(CliErrorKind::workflow_io(format!(
                "terminal agent '{}' is already active in host bridge",
                spec.tui_id
            ))
            .into());
        }
        let process = spawn_agent_tui_process(
            &spec.session_id,
            &spec.tui_id,
            spec.profile.clone(),
            &spec.project_dir,
            spec.size,
            spec.prompt.clone(),
            spec.effort.as_deref(),
        )?;
        let deferred_prompt = bridge_deferred_auto_join(&spec.profile.runtime, spec.prompt.clone());
        let deferred_runtime = spec.profile.runtime.clone();
        let deferred_tui_id = spec.tui_id.clone();
        let process = Arc::new(process);
        let context = BridgeSnapshotContext {
            session_id: spec.session_id,
            agent_id: spec.agent_id,
            tui_id: spec.tui_id.clone(),
            profile: spec.profile,
            project_dir: spec.project_dir,
            transcript_path: spec.transcript_path,
        };
        let snapshot =
            snapshot_from_process(&context.borrowed(), &process, AgentTuiStatus::Running)?;
        self.active_tuis()?.insert(
            spec.tui_id,
            BridgeActiveTui {
                process,
                context,
                created_at: snapshot.created_at.clone(),
            },
        );
        self.update_agent_tui_metadata()?;

        // Send PTY-delivered prompts in background so the bridge response
        // returns immediately. CLI-injected runtimes already received the
        // prompt in argv and must not be sent the same join command again.
        if let Some(prompt) = deferred_prompt {
            let process = Arc::clone(&self.active_tui(&deferred_tui_id)?.process);
            thread::spawn(move || {
                deliver_deferred_prompts(
                    &process,
                    &deferred_runtime,
                    &deferred_tui_id,
                    &prompt,
                    None,
                );
            });
        }

        Ok(snapshot)
    }

    pub(super) fn get_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tui(tui_id)?;
        let mut status = AgentTuiStatus::Running;
        let mut exit_code = None;
        let mut signal = None;
        if let Some(exit_status) = active.process.try_wait()? {
            status = AgentTuiStatus::Exited;
            exit_code = Some(exit_status.exit_code());
            signal = exit_status.signal().map(ToString::to_string);
            let _ = self.active_tuis()?.remove(tui_id);
            self.update_agent_tui_metadata()?;
        }
        let mut snapshot =
            snapshot_from_process(&active.context.borrowed(), &active.process, status)?;
        snapshot.created_at = active.created_at;
        snapshot.exit_code = exit_code;
        snapshot.signal = signal;
        Ok(snapshot)
    }

    pub(super) fn stop_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tuis()?.remove(tui_id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "terminal agent '{tui_id}' is not active in host bridge"
            ))
        })?;
        active.process.kill()?;
        let _ = active.process.wait_timeout(Duration::from_millis(500))?;
        let mut snapshot = snapshot_from_process(
            &active.context.borrowed(),
            &active.process,
            AgentTuiStatus::Stopped,
        )?;
        snapshot.created_at = active.created_at;
        self.update_agent_tui_metadata()?;
        Ok(snapshot)
    }

    pub(super) fn active_tui(&self, tui_id: &str) -> Result<BridgeActiveTui, CliError> {
        self.active_tuis()?.get(tui_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "terminal agent '{tui_id}' is not active in host bridge"
            ))
            .into()
        })
    }

    pub(super) fn update_agent_tui_metadata(&self) -> Result<(), CliError> {
        let active_sessions = self.active_tuis()?.len();
        let metadata = BridgeAgentTuiMetadata { active_sessions };
        let manifest = HostBridgeCapabilityManifest {
            enabled: true,
            healthy: true,
            transport: "unix".to_string(),
            endpoint: Some(self.socket_path.display().to_string()),
            metadata: stringify_metadata_map(&metadata),
        };
        self.capabilities()?
            .insert(BRIDGE_CAPABILITY_AGENT_TUI.to_string(), manifest);
        self.persist_state()
    }

    pub(super) fn attach_agent_tui(
        &self,
        tui_id: &str,
    ) -> Result<(Arc<AgentTuiProcess>, AgentTuiAttachState), CliError> {
        let active = self.active_tui(tui_id)?;
        Ok((Arc::clone(&active.process), active.process.attach_state()?))
    }
}

fn bridge_deferred_auto_join(runtime: &str, prompt: Option<String>) -> Option<String> {
    let delivery = runtime_for_name(runtime).map_or(
        InitialPromptDelivery::PtySend,
        AgentRuntime::initial_prompt_delivery,
    );
    match delivery {
        InitialPromptDelivery::PtySend => prompt.filter(|value| !value.is_empty()),
        InitialPromptDelivery::CliPositional | InitialPromptDelivery::CliFlag(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::bridge_deferred_auto_join;

    #[test]
    fn deferred_auto_join_skips_cli_prompt_runtimes() {
        assert_eq!(
            bridge_deferred_auto_join("claude", Some("join".into())),
            None
        );
        assert_eq!(
            bridge_deferred_auto_join("gemini", Some("join".into())),
            None
        );
        assert_eq!(bridge_deferred_auto_join("vibe", Some("join".into())), None);
    }

    #[test]
    fn deferred_auto_join_keeps_pty_runtimes() {
        assert_eq!(
            bridge_deferred_auto_join("codex", Some("join".into())),
            Some("join".into())
        );
        assert_eq!(
            bridge_deferred_auto_join("copilot", Some("join".into())),
            Some("join".into())
        );
    }
}
