use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::ordering::sort_agent_tui_snapshots;
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::manager::AgentTuiManagerHandle;
use super::model::{
    AgentTuiInputRequest, AgentTuiLaunchProfile, AgentTuiListResponse, AgentTuiSnapshot,
    AgentTuiStatus,
};
use super::process::{AgentTuiSnapshotContext, snapshot_from_process};
use super::readiness::signal_readiness_ready;
use super::support::lock_db;
use super::{AgentTuiInput, AgentTuiKey, AgentTuiResizeRequest};

impl AgentTuiManagerHandle {
    /// List managed TUI snapshots for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] when DB access fails.
    pub fn list(&self, session_id: &str) -> Result<AgentTuiListResponse, CliError> {
        let session_id_owned = session_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            let mut tuis = async_db.list_agent_tuis(&session_id_owned).await?;
            let roles_by_agent = async_db
                .resolve_session(&session_id_owned)
                .await?
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
        }) {
            return result;
        }
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
                    input: AgentTuiInput::Text {
                        text: prompt.to_string(),
                    },
                },
            )?;
            let _ = bridge.agent_tui_input(
                tui_id,
                &AgentTuiInputRequest {
                    input: AgentTuiInput::Key {
                        key: AgentTuiKey::Enter,
                    },
                },
            )?;
            return Ok(true);
        }

        let process = self.active_process(tui_id)?;
        process.send_input(&AgentTuiInput::Text {
            text: prompt.to_string(),
        })?;
        process.send_input(&AgentTuiInput::Key {
            key: AgentTuiKey::Enter,
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
        request: &AgentTuiResizeRequest,
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

    /// Signal that a terminal agent is ready to accept input.
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
        tracing::info!(tui_id = %tui_id, "terminal agent readiness signaled via callback");
        self.get(tui_id)
    }
}
