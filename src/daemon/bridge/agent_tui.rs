use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use crate::agents::runtime::{AgentRuntime, InitialPromptDelivery, runtime_for_name};
use crate::daemon::agent_tui::{
    AgentTuiAttachState, AgentTuiInputWorker, AgentTuiProcess, AgentTuiSnapshot,
    AgentTuiStatus, deliver_deferred_prompts, snapshot_from_process, spawn_agent_tui_process,
};
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::errors::{CliError, CliErrorKind};

use super::core::{
    BridgeActiveTui, BridgeAgentTuiMetadata, BridgeSnapshotContext, BridgeTuiExitInfo,
};
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
        let stop_flag = Arc::new(AtomicBool::new(false));
        let input_worker = AgentTuiInputWorker::spawn(Arc::clone(&process), Arc::clone(&stop_flag));
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
                stop_flag,
                input_worker,
                context,
                created_at: snapshot.created_at.clone(),
                exit_info: None,
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
        let exit_info = self.resolve_tui_exit_state(tui_id)?;
        let active = self.active_tui(tui_id)?;
        let (status, exit_code, signal) = exit_info
            .map_or((AgentTuiStatus::Running, None, None), |info| {
                (info.status, info.exit_code, info.signal)
            });
        let mut snapshot =
            snapshot_from_process(&active.context.borrowed(), &active.process, status)?;
        snapshot.created_at = active.created_at;
        snapshot.exit_code = exit_code;
        snapshot.signal = signal;
        Ok(snapshot)
    }

    /// Return the cached exit info for `tui_id`, detecting fresh exits via
    /// `try_wait` when needed. The entry stays in `active_tuis` so repeat
    /// queries remain idempotent until `stop_agent_tui` removes it.
    fn resolve_tui_exit_state(&self, tui_id: &str) -> Result<Option<BridgeTuiExitInfo>, CliError> {
        let mut active_tuis = self.active_tuis()?;
        let entry = active_tuis.get_mut(tui_id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "terminal agent '{tui_id}' is not active in host bridge"
            ))
        })?;
        if let Some(info) = &entry.exit_info {
            return Ok(Some(info.clone()));
        }
        let Some(exit_status) = entry.process.try_wait()? else {
            return Ok(None);
        };
        let info = BridgeTuiExitInfo {
            status: AgentTuiStatus::Exited,
            exit_code: Some(exit_status.exit_code()),
            signal: exit_status.signal().map(ToString::to_string),
        };
        entry.exit_info = Some(info.clone());
        Ok(Some(info))
    }

    pub(super) fn stop_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tuis()?.remove(tui_id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "terminal agent '{tui_id}' is not active in host bridge"
            ))
        })?;
        active.stop_flag.store(true, Ordering::Relaxed);
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
    use std::collections::BTreeMap;
    use std::sync::Arc;
    use std::sync::atomic::AtomicBool;
    use std::time::Duration;

    use crate::daemon::agent_tui::{
        AgentTuiBackend, AgentTuiInputWorker, AgentTuiLaunchProfile, AgentTuiSize,
        AgentTuiSpawnSpec, AgentTuiStatus, PortablePtyAgentTuiBackend,
    };
    use crate::daemon::bridge::core::{BridgeActiveTui, BridgeSnapshotContext};
    use crate::daemon::bridge::server::BridgeServer;
    use crate::daemon::bridge::types::PersistedBridgeConfig;
    use crate::daemon::state::HostBridgeCapabilityManifest;

    use super::bridge_deferred_auto_join;

    fn make_test_server(tmp: &std::path::Path) -> Arc<BridgeServer> {
        Arc::new(BridgeServer::new(
            "test-token".to_string(),
            tmp.join("bridge.sock"),
            PersistedBridgeConfig::default(),
            BTreeMap::<String, HostBridgeCapabilityManifest>::new(),
        ))
    }

    fn spawn_quick_exit_tui(tmp: &std::path::Path, tui_id: &str) -> BridgeActiveTui {
        let profile = AgentTuiLaunchProfile::from_argv(
            "codex",
            vec!["sh".to_string(), "-c".to_string(), "exit 0".to_string()],
        )
        .expect("profile");
        let spec = AgentTuiSpawnSpec::new(
            profile.clone(),
            tmp.to_path_buf(),
            BTreeMap::new(),
            AgentTuiSize { rows: 5, cols: 40 },
        )
        .expect("spec");
        let process = Arc::new(PortablePtyAgentTuiBackend.spawn(spec).expect("spawn"));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let transcript_path = tmp.join("transcript.raw");
        BridgeActiveTui {
            input_worker: AgentTuiInputWorker::spawn(Arc::clone(&process), Arc::clone(&stop_flag)),
            process,
            stop_flag,
            context: BridgeSnapshotContext {
                session_id: "sess".into(),
                agent_id: String::new(),
                tui_id: tui_id.into(),
                profile,
                project_dir: tmp.to_path_buf(),
                transcript_path,
            },
            created_at: "2026-04-22T09:00:00Z".into(),
            exit_info: None,
        }
    }

    #[test]
    fn get_agent_tui_is_idempotent_after_child_exit() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let server = make_test_server(tmp.path());
        let tui_id = "bridge-tui-exit".to_string();
        let active = spawn_quick_exit_tui(tmp.path(), &tui_id);
        server
            .active_tuis
            .lock()
            .expect("active lock")
            .insert(tui_id.clone(), active);

        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        let mut first_exited = None;
        while std::time::Instant::now() < deadline {
            match server.get_agent_tui(&tui_id) {
                Ok(snapshot) if snapshot.status == AgentTuiStatus::Exited => {
                    first_exited = Some(snapshot);
                    break;
                }
                Ok(_) => std::thread::sleep(Duration::from_millis(25)),
                Err(error) => panic!("unexpected get failure: {error}"),
            }
        }
        let first = first_exited.expect("tui should transition to Exited within timeout");
        assert_eq!(first.status, AgentTuiStatus::Exited);

        // Repeated get after exit must stay idempotent: return the same Exited
        // snapshot instead of surfacing a "not active" error.
        let second = server
            .get_agent_tui(&tui_id)
            .expect("idempotent get after exit");
        assert_eq!(second.status, AgentTuiStatus::Exited);
        assert_eq!(second.exit_code, first.exit_code);
        assert_eq!(second.tui_id, tui_id);
    }

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
