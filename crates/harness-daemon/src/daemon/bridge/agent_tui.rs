use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::daemon::agent_tui::{
    AgentTuiAttachState, AgentTuiInputWorker, AgentTuiProcess, AgentTuiSnapshot, AgentTuiStatus,
    ManagedTerminalOwner, deliver_deferred_prompts, signal_readiness_ready, snapshot_from_process,
    spawn_agent_tui_process,
};
use crate::daemon::state::HostBridgeCapabilityManifest;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::agent_tui_launch::{
    bridge_deferred_auto_join, ensure_agent_tui_running, ensure_same_agent_tui_launch,
};
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
        let mut active_tuis = self.active_tuis()?;
        if let Some(active) = active_tuis.get(&spec.tui_id) {
            ensure_same_agent_tui_launch(&active.launch_spec, &spec)?;
            drop(active_tuis);
            let snapshot = self.get_agent_tui(&spec.tui_id)?;
            ensure_agent_tui_running(&snapshot)?;
            return Ok(snapshot);
        }
        let process = spawn_agent_tui_process(
            spec.workspace_id.as_deref().map_or(
                ManagedTerminalOwner::Session(&spec.session_id),
                ManagedTerminalOwner::Workspace,
            ),
            &spec.tui_id,
            spec.profile.clone(),
            &spec.project_dir,
            spec.size,
            spec.prompt.clone(),
            spec.effort.as_deref(),
        )?;
        let deferred_prompt = bridge_deferred_auto_join(&spec.profile.runtime, spec.prompt.clone());
        let deferred_user_prompt = spec.user_prompt.clone().filter(|value| !value.is_empty());
        let deferred_runtime = spec.profile.runtime.clone();
        let deferred_tui_id = spec.tui_id.clone();
        let startup_error = Arc::new(Mutex::new(None));
        let process = Arc::new(process);
        let stop_flag = Arc::new(AtomicBool::new(false));
        let input_worker = AgentTuiInputWorker::spawn(Arc::clone(&process), Arc::clone(&stop_flag));
        let context = BridgeSnapshotContext {
            session_id: spec.session_id.clone(),
            agent_id: spec.agent_id.clone(),
            tui_id: spec.tui_id.clone(),
            profile: spec.profile.clone(),
            project_dir: spec.project_dir.clone(),
            transcript_path: spec.transcript_path.clone(),
        };
        let snapshot =
            snapshot_from_process(&context.borrowed(), &process, AgentTuiStatus::Running)?;
        active_tuis.insert(
            spec.tui_id.clone(),
            BridgeActiveTui {
                process,
                stop_flag,
                input_worker,
                context,
                launch_spec: spec,
                created_at: snapshot.created_at.clone(),
                exit_info: None,
                startup_error: Arc::clone(&startup_error),
            },
        );
        drop(active_tuis);
        self.update_agent_tui_metadata()?;

        // Send PTY-delivered prompts in background so the bridge response
        // returns immediately. CLI-injected runtimes already received the
        // auto-join in argv and must not be sent the same join command again,
        // but their user prompt still has to wait for readiness.
        if deferred_prompt.is_some() || deferred_user_prompt.is_some() {
            let process = Arc::clone(&self.active_tui(&deferred_tui_id)?.process);
            thread::spawn(move || {
                let problem = deliver_deferred_prompts(
                    &process,
                    &deferred_runtime,
                    &deferred_tui_id,
                    deferred_prompt.as_deref(),
                    deferred_user_prompt.as_deref(),
                );
                if let Some(problem) = problem
                    && let Ok(mut slot) = startup_error.lock()
                {
                    *slot = Some(problem);
                }
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
        snapshot.error = active
            .startup_error
            .lock()
            .ok()
            .and_then(|slot| slot.clone());
        Ok(snapshot)
    }

    /// Release the deferred join for a bridge-hosted terminal agent.
    ///
    /// The sandboxed daemon holds no process handle, so the `SessionStart`
    /// readiness callback has to travel here. Without it nothing signals the
    /// PTY-side condvar for runtimes that have no readiness pattern, and the
    /// join is typed blind once the readiness timeout elapses.
    pub(super) fn signal_agent_tui_ready(
        &self,
        tui_id: &str,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tui(tui_id)?;
        signal_readiness_ready(&active.process.readiness_signal());
        self.get_agent_tui(tui_id)
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

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::sync::Arc;
    use std::sync::Barrier;
    use std::sync::Mutex;
    use std::sync::atomic::AtomicBool;
    use std::time::Duration;

    use crate::daemon::agent_tui::{
        AgentTuiBackend, AgentTuiInputWorker, AgentTuiLaunchProfile, AgentTuiSize,
        AgentTuiSpawnSpec, AgentTuiStatus, PortablePtyAgentTuiBackend,
    };
    use crate::daemon::bridge::core::{BridgeActiveTui, BridgeSnapshotContext};
    use crate::daemon::bridge::server::BridgeServer;
    use crate::daemon::bridge::types::{
        AgentTuiStartSpec, BRIDGE_CAPABILITY_AGENT_TUI, PersistedBridgeConfig,
    };
    use crate::daemon::state::HostBridgeCapabilityManifest;

    use super::{bridge_deferred_auto_join, ensure_same_agent_tui_launch};

    fn make_test_server(tmp: &std::path::Path) -> Arc<BridgeServer> {
        let capabilities = BTreeMap::from([(
            BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "unix".into(),
                endpoint: None,
                metadata: BTreeMap::new(),
            },
        )]);
        Arc::new(BridgeServer::new(
            "test-token".to_string(),
            tmp.join("bridge.sock"),
            PersistedBridgeConfig::default(),
            capabilities,
        ))
    }

    fn spawn_quick_exit_tui(tmp: &std::path::Path, tui_id: &str) -> BridgeActiveTui {
        let profile = AgentTuiLaunchProfile::from_argv(
            "codex",
            vec!["sh".to_string(), "-c".to_string(), "exit 0".to_string()],
        )
        .expect("profile");
        let size = AgentTuiSize { rows: 5, cols: 40 };
        let transcript_path = tmp.join("transcript.raw");
        let launch_spec = AgentTuiStartSpec {
            session_id: "sess".into(),
            workspace_id: None,
            agent_id: String::new(),
            tui_id: tui_id.into(),
            profile: profile.clone(),
            project_dir: tmp.to_path_buf(),
            transcript_path: transcript_path.clone(),
            size,
            prompt: None,
            user_prompt: None,
            effort: None,
        };
        let spec =
            AgentTuiSpawnSpec::new(profile.clone(), tmp.to_path_buf(), BTreeMap::new(), size)
                .expect("spec");
        let process = Arc::new(PortablePtyAgentTuiBackend.spawn(spec).expect("spawn"));
        let stop_flag = Arc::new(AtomicBool::new(false));
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
            launch_spec,
            created_at: "2026-04-22T09:00:00Z".into(),
            exit_info: None,
            startup_error: Arc::new(Mutex::new(None)),
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

    /// A sandboxed daemon reads a bridge-hosted TUI only through these
    /// snapshots, so a startup problem that never lands on one is invisible.
    #[test]
    fn get_agent_tui_surfaces_a_recorded_startup_error() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let server = make_test_server(tmp.path());
        let tui_id = "bridge-tui-startup-error".to_string();
        let active = spawn_quick_exit_tui(tmp.path(), &tui_id);
        let startup_error = Arc::clone(&active.startup_error);
        server
            .active_tuis
            .lock()
            .expect("active lock")
            .insert(tui_id.clone(), active);

        assert_eq!(
            server.get_agent_tui(&tui_id).expect("clean get").error,
            None
        );

        *startup_error.lock().expect("startup error lock") =
            Some("terminal agent never signaled readiness".to_string());

        assert_eq!(
            server
                .get_agent_tui(&tui_id)
                .expect("get after failure")
                .error
                .as_deref(),
            Some("terminal agent never signaled readiness")
        );
    }

    #[test]
    fn signal_agent_tui_ready_releases_the_deferred_join() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let server = make_test_server(tmp.path());
        let tui_id = "bridge-tui-ready".to_string();
        let active = spawn_quick_exit_tui(tmp.path(), &tui_id);
        let process = Arc::clone(&active.process);
        server
            .active_tuis
            .lock()
            .expect("active lock")
            .insert(tui_id.clone(), active);

        server
            .signal_agent_tui_ready(&tui_id)
            .expect("signal readiness over the bridge");

        assert!(
            process.wait_ready(Duration::from_millis(0)),
            "the bridge-held PTY must be marked ready without waiting out the timeout"
        );
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

    #[test]
    fn active_bridge_tui_is_reusable_only_for_the_same_launch() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let profile =
            AgentTuiLaunchProfile::from_argv("codex", vec!["codex".into()]).expect("profile");
        let spec = AgentTuiStartSpec {
            session_id: "session-1".into(),
            workspace_id: None,
            agent_id: String::new(),
            tui_id: "stable-tui".into(),
            profile: profile.clone(),
            project_dir: tmp.path().to_path_buf(),
            transcript_path: tmp.path().join("transcript.raw"),
            size: AgentTuiSize { rows: 24, cols: 80 },
            prompt: None,
            user_prompt: None,
            effort: None,
        };
        ensure_same_agent_tui_launch(&spec, &spec).expect("matching launch is reusable");

        let mut mismatched = spec.clone();
        mismatched.session_id = "session-2".into();
        assert!(ensure_same_agent_tui_launch(&spec, &mismatched).is_err());

        let mut changed_prompt = spec.clone();
        changed_prompt.prompt = Some("different worker contract".into());
        assert!(ensure_same_agent_tui_launch(&spec, &changed_prompt).is_err());

        let mut changed_effort = spec.clone();
        changed_effort.effort = Some("high".into());
        assert!(ensure_same_agent_tui_launch(&spec, &changed_effort).is_err());
    }

    #[test]
    fn concurrent_idempotent_starts_share_one_bridge_tui() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let server = make_test_server(tmp.path());
        let spec = AgentTuiStartSpec {
            session_id: "session-concurrent".into(),
            workspace_id: None,
            agent_id: String::new(),
            tui_id: "stable-concurrent-tui".into(),
            profile: AgentTuiLaunchProfile::from_argv(
                "codex",
                vec!["sh".into(), "-c".into(), "cat".into()],
            )
            .expect("profile"),
            project_dir: tmp.path().to_path_buf(),
            transcript_path: tmp.path().join("concurrent-transcript.raw"),
            size: AgentTuiSize { rows: 8, cols: 40 },
            prompt: None,
            user_prompt: None,
            effort: None,
        };
        let barrier = Arc::new(Barrier::new(2));
        let start = |server: Arc<BridgeServer>, spec: AgentTuiStartSpec, barrier: Arc<Barrier>| {
            std::thread::spawn(move || {
                barrier.wait();
                server.start_agent_tui(spec)
            })
        };
        temp_env::with_var(
            "HARNESS_DAEMON_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 temp path")),
            || {
                let first = start(Arc::clone(&server), spec.clone(), Arc::clone(&barrier));
                let second = start(Arc::clone(&server), spec.clone(), Arc::clone(&barrier));
                let first = first
                    .join()
                    .expect("first start thread")
                    .expect("first start");
                let second = second
                    .join()
                    .expect("second start thread")
                    .expect("second start");
                assert_eq!(first.tui_id, spec.tui_id);
                assert_eq!(first.created_at, second.created_at);
                assert_eq!(server.active_tuis().expect("active map").len(), 1);
                server
                    .stop_agent_tui(&spec.tui_id)
                    .expect("stop shared tui");
            },
        );
    }
}
