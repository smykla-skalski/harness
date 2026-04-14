use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use tokio::sync::broadcast;
use uuid::Uuid;

use crate::agents::runtime::{AgentRuntime, InitialPromptDelivery, runtime_for_name};
use crate::daemon::bridge::{AgentTuiStartSpec, BridgeCapability, BridgeClient};
use crate::daemon::db::DaemonDb;
use crate::daemon::ordering::sort_agent_tui_snapshots;
use crate::daemon::protocol::StreamEvent;
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::model::{
    AgentTuiInputRequest, AgentTuiLaunchProfile, AgentTuiListResponse, AgentTuiSnapshot,
    AgentTuiStartRequest, AgentTuiStatus,
};
use super::process::{AgentTuiProcess, AgentTuiSnapshotContext, snapshot_from_process};
use super::readiness::signal_readiness_ready;
use super::spawn::{
    build_auto_join_prompt, deliver_deferred_prompts, send_initial_prompt, spawn_agent_tui_process,
    wait_for_readiness,
};
use super::support::{lock_db, resolve_tui_project, transcript_path};

#[derive(Clone)]
pub(crate) struct ActiveAgentTui {
    pub(crate) process: Option<Arc<AgentTuiProcess>>,
    pub(crate) stop_flag: Arc<AtomicBool>,
}

impl ActiveAgentTui {
    pub(crate) fn new(process: Option<Arc<AgentTuiProcess>>) -> Self {
        Self {
            process,
            stop_flag: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }
}

/// Daemon-owned manager for interactive agent runtime PTYs.
#[derive(Clone)]
pub struct AgentTuiManagerHandle {
    pub(crate) state: Arc<AgentTuiManagerState>,
}

pub(crate) struct AgentTuiManagerState {
    pub(crate) sender: broadcast::Sender<StreamEvent>,
    pub(crate) db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub(crate) active: Mutex<BTreeMap<String, ActiveAgentTui>>,
    pub(crate) sandboxed: bool,
}

impl AgentTuiManagerHandle {
    /// Create a manager bound to the daemon DB and event stream.
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        sandboxed: bool,
    ) -> Self {
        Self {
            state: Arc::new(AgentTuiManagerState {
                sender,
                db,
                active: Mutex::new(BTreeMap::new()),
                sandboxed,
            }),
        }
    }

    /// Start an agent runtime in a PTY.
    ///
    /// The agent is **not** registered in session state here. Registration
    /// happens when the auto-join skill invocation executes inside the PTY,
    /// preventing the duplicate-registration bug that occurred when both the
    /// daemon and the skill called `join_session`.
    ///
    /// # Errors
    /// Returns [`CliError`] when the daemon DB is unavailable or PTY/process
    /// setup fails.
    pub fn start(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            return self.start_via_bridge(session_id, request);
        }

        let profile = request.launch_profile()?;
        let size = request.size()?;
        let tui_id = format!("agent-tui-{}", Uuid::new_v4());
        let project = {
            let db = self.db()?;
            let db_guard = lock_db(&db)?;
            resolve_tui_project(&db_guard, session_id, request.project_dir.as_deref())?
        };

        let transcript_path = transcript_path(&project.context_root, &profile.runtime, &tui_id);
        let snapshot_context = AgentTuiSnapshotContext {
            session_id,
            agent_id: "",
            tui_id: &tui_id,
            profile: &profile,
            project_dir: &project.project_dir,
            transcript_path: &transcript_path,
        };
        let auto_join = build_auto_join_prompt(
            &profile.runtime,
            session_id,
            request.role,
            &request.capabilities,
            &tui_id,
            request.name.as_deref(),
            request.persona.as_deref(),
        );
        let process = spawn_agent_tui_process(
            session_id,
            &tui_id,
            profile.clone(),
            &project.project_dir,
            size,
            Some(auto_join.clone()),
        )?;

        let result = self.activate_tui(process, &snapshot_context);
        if let Ok(snapshot) = &result {
            self.spawn_deferred_join(
                snapshot.clone(),
                profile.runtime.clone(),
                &auto_join,
                request,
            );
        }
        result
    }

    /// Spawn a background thread that waits for the readiness callback (or
    /// timeout), then delivers any PTY-based prompts and broadcasts the
    /// `agent_tui_ready` event.
    ///
    /// For `CliPositional`/`CliFlag` runtimes the join prompt was already
    /// injected into the CLI argv, so the thread only waits + broadcasts.
    /// For `PtySend` runtimes it also sends the join via PTY after readiness.
    fn spawn_deferred_join(
        &self,
        snapshot: AgentTuiSnapshot,
        runtime: String,
        auto_join: &str,
        request: &AgentTuiStartRequest,
    ) {
        let delivery = runtime_for_name(&runtime)
            .map_or(InitialPromptDelivery::PtySend, AgentRuntime::initial_prompt_delivery);
        let pty_auto_join = matches!(delivery, InitialPromptDelivery::PtySend)
        .then(|| auto_join.to_string());
        let user_prompt = request
            .prompt
            .as_deref()
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let tui_id = snapshot.tui_id.clone();
        let manager = self.clone();

        thread::spawn(
            #[expect(
                clippy::cognitive_complexity,
                reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
            )]
            move || {
                let Ok(process) = manager.active_process(&tui_id) else {
                    tracing::warn!(tui_id = %tui_id, "deferred join: TUI no longer active");
                    return;
                };
                wait_for_readiness(&process, &runtime, &tui_id);
                if let Some(join_prompt) = &pty_auto_join {
                    deliver_deferred_prompts(
                        &process,
                        &runtime,
                        &tui_id,
                        join_prompt,
                        user_prompt.as_deref(),
                    );
                } else if let Some(prompt) = &user_prompt
                    && let Err(error) = send_initial_prompt(&process, prompt)
                {
                    tracing::warn!(%error, "failed to send user prompt");
                }
                let _ = manager.save_and_broadcast("agent_tui_ready", &snapshot);
            },
        );
    }

    fn activate_tui(
        &self,
        process: AgentTuiProcess,
        context: &AgentTuiSnapshotContext<'_>,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let process = Arc::new(process);
        let snapshot = snapshot_from_process(context, &process, AgentTuiStatus::Running)?;
        let active = ActiveAgentTui::new(Some(Arc::clone(&process)));
        let stop_flag = Arc::clone(&active.stop_flag);
        let tui_id = context.tui_id.to_string();
        self.active()?.insert(tui_id.clone(), active);
        if let Err(error) = self.save_and_broadcast("agent_tui_started", &snapshot) {
            let _ = self.remove_active(&tui_id)?;
            return Err(error);
        }
        self.spawn_live_refresh(tui_id, stop_flag);
        Ok(snapshot)
    }

    fn start_via_bridge(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let profile = request.launch_profile()?;
        let size = request.size()?;
        let tui_id = format!("agent-tui-{}", Uuid::new_v4());
        let bridge = BridgeClient::for_capability(BridgeCapability::AgentTui)?;
        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        let project = resolve_tui_project(&db_guard, session_id, request.project_dir.as_deref())?;
        drop(db_guard);

        let auto_join = build_auto_join_prompt(
            &profile.runtime,
            session_id,
            request.role,
            &request.capabilities,
            &tui_id,
            request.name.as_deref(),
            request.persona.as_deref(),
        );

        let transcript_path = transcript_path(&project.context_root, &profile.runtime, &tui_id);
        let snapshot = bridge.agent_tui_start(&AgentTuiStartSpec {
            session_id: session_id.to_string(),
            agent_id: String::new(),
            tui_id,
            profile,
            project_dir: project.project_dir,
            transcript_path,
            size,
            prompt: Some(auto_join),
        })?;
        let active = ActiveAgentTui::new(None);
        let stop_flag = Arc::clone(&active.stop_flag);
        self.active()?.insert(snapshot.tui_id.clone(), active);
        if let Err(error) = self.save_and_broadcast("agent_tui_started", &snapshot) {
            let _ = self.remove_active(&snapshot.tui_id)?;
            return Err(error);
        }
        self.spawn_live_refresh(snapshot.tui_id.clone(), stop_flag);
        Ok(snapshot)
    }

    /// List managed TUI snapshots for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] when DB access fails.
    pub fn list(&self, session_id: &str) -> Result<AgentTuiListResponse, CliError> {
        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        let mut tuis = db_guard.list_agent_tuis(session_id)?;
        let roles_by_agent = db_guard
            .resolve_session(session_id)?
            .map(|resolved| {
                resolved
                    .state
                    .agents
                    .into_iter()
                    .map(|(agent_id, agent)| (agent_id, agent.role))
                    .collect::<BTreeMap<_, _>>()
            })
            .unwrap_or_default();
        sort_agent_tui_snapshots(&mut tuis, &roles_by_agent);
        Ok(AgentTuiListResponse { tuis })
    }

    /// Load a managed TUI snapshot by ID, refreshing live screen/process state when active.
    ///
    /// # Errors
    /// Returns [`CliError`] when DB access fails or the TUI is missing.
    pub fn get(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let previous = self.load_snapshot(tui_id)?;
        let refreshed = self.refresh_live_snapshot(previous.clone())?;
        self.persist_refreshed_snapshot(&previous, &refreshed)?;
        Ok(refreshed)
    }

    /// Send keyboard-like input into an active TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is inactive or input/write fails.
    pub fn input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            let snapshot = self.normalize_snapshot(
                BridgeClient::for_capability(BridgeCapability::AgentTui)?
                    .agent_tui_input(tui_id, request)?,
            );
            self.save_and_broadcast("agent_tui_updated", &snapshot)?;
            return Ok(snapshot);
        }
        let process = self.active_process(tui_id)?;
        process.send_input(&request.input)?;
        self.get(tui_id)
    }

    /// Send a prompt directly to a managed TUI without refreshing DB state.
    ///
    /// Returns `Ok(false)` when the target TUI is no longer active.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI input transport fails.
    pub fn prompt_tui(&self, tui_id: &str, prompt: &str) -> Result<bool, CliError> {
        if !self.is_tui_active(tui_id)? {
            return Ok(false);
        }
        if self.state.sandboxed {
            let bridge = BridgeClient::for_capability(BridgeCapability::AgentTui)?;
            let _ = bridge.agent_tui_input(
                tui_id,
                &AgentTuiInputRequest {
                    input: super::AgentTuiInput::Text {
                        text: prompt.to_string(),
                    },
                },
            )?;
            let _ = bridge.agent_tui_input(
                tui_id,
                &AgentTuiInputRequest {
                    input: super::AgentTuiInput::Key {
                        key: super::AgentTuiKey::Enter,
                    },
                },
            )?;
            return Ok(true);
        }

        let process = self.active_process(tui_id)?;
        process.send_input(&super::AgentTuiInput::Text {
            text: prompt.to_string(),
        })?;
        process.send_input(&super::AgentTuiInput::Key {
            key: super::AgentTuiKey::Enter,
        })?;
        Ok(true)
    }

    /// Resize an active TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is inactive or resize fails.
    pub fn resize(
        &self,
        tui_id: &str,
        request: &super::AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            let snapshot = self.normalize_snapshot(
                BridgeClient::for_capability(BridgeCapability::AgentTui)?
                    .agent_tui_resize(tui_id, request)?,
            );
            self.save_and_broadcast("agent_tui_updated", &snapshot)?;
            return Ok(snapshot);
        }
        let process = self.active_process(tui_id)?;
        process.resize(request.size()?)?;
        self.get(tui_id)
    }

    /// Stop an active TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is missing or process termination fails.
    #[expect(
        clippy::cognitive_complexity,
        reason = "bridge fallback adds one branch"
    )]
    pub fn stop(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let snapshot = self.load_snapshot(tui_id)?;
        if self.state.sandboxed && snapshot.status == AgentTuiStatus::Running {
            match BridgeClient::for_capability(BridgeCapability::AgentTui)
                .and_then(|bridge| bridge.agent_tui_stop(tui_id))
            {
                Ok(stopped) => {
                    let stopped = self.normalize_snapshot(stopped);
                    let _ = self.remove_active(tui_id)?;
                    self.save_and_broadcast("agent_tui_stopped", &stopped)?;
                    return Ok(stopped);
                }
                Err(error) => {
                    tracing::warn!(
                        %error,
                        tui_id,
                        "bridge unreachable during stop, falling back to local cleanup"
                    );
                }
            }
        }
        let process = self.remove_active(tui_id)?;
        if let Some(process) = process {
            process.kill()?;
            let _ = process.wait_timeout(Duration::from_millis(500))?;
            let profile =
                AgentTuiLaunchProfile::from_argv(&snapshot.runtime, snapshot.argv.clone())?;
            let snapshot_context = AgentTuiSnapshotContext {
                session_id: &snapshot.session_id,
                agent_id: &snapshot.agent_id,
                tui_id: &snapshot.tui_id,
                profile: &profile,
                project_dir: Path::new(&snapshot.project_dir),
                transcript_path: Path::new(&snapshot.transcript_path),
            };
            let mut stopped =
                snapshot_from_process(&snapshot_context, &process, AgentTuiStatus::Stopped)?;
            stopped.created_at = snapshot.created_at;
            let stopped = self.normalize_snapshot(stopped);
            self.save_and_broadcast("agent_tui_stopped", &stopped)?;
            return Ok(stopped);
        }

        let mut stopped = snapshot;
        stopped.status = AgentTuiStatus::Stopped;
        stopped.updated_at = utc_now();
        let stopped = self.normalize_snapshot(stopped);
        self.save_and_broadcast("agent_tui_stopped", &stopped)?;
        Ok(stopped)
    }

    /// Signal that an agent TUI is ready to accept input.
    ///
    /// Called by the `SessionStart` hook callback. Sets the readiness condvar
    /// so the deferred join thread can proceed. Idempotent - calling twice is
    /// a no-op.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is not active or the snapshot cannot
    /// be loaded.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub fn signal_ready(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let process = self.active_process(tui_id)?;
        signal_readiness_ready(&process.readiness_signal());
        tracing::info!(tui_id = %tui_id, "agent TUI readiness signaled via callback");
        self.get(tui_id)
    }
}
