use std::sync::atomic::Ordering;
use std::sync::{Arc, Weak};

use tokio::task::spawn_blocking;

use super::{AcpAgentManagerHandle, AcpAgentSnapshot};
use crate::agents::kind::DisconnectReason;
use crate::daemon::agent_acp::active::{ActiveAcpSession, process_incident_from_snapshot};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::sandboxed_from_env;
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

impl AcpAgentManagerHandle {
    /// Stop an ACP session and fail every pending permission with daemon shutdown.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if sandboxed_from_env() {
            return self.stop_via_bridge(acp_id);
        }
        let session = self.session(acp_id)?;
        let _lifecycle = self.process_lifecycle_guard()?;
        let before = session.snapshot_with_live_counts();
        if before.status.is_disconnected() {
            return Ok(before);
        }
        let process_key = session.process_key();
        let pending_permissions = session.disconnect_for_stop().map_err(|error| {
            CliErrorKind::workflow_io(format!("detach ACP protocol session '{acp_id}': {error}"))
        })?;
        if session.process().logical_session_count() == 0 {
            session.terminate_process(pending_permissions);
            self.remove_process_if_empty(&process_key)?;
        }
        let snapshot = session.snapshot_with_live_counts();
        self.sync_orchestration_disconnect_best_effort(&snapshot);
        self.broadcast("acp_agent_stopped", &snapshot);
        Ok(snapshot)
    }

    /// Fail all live ACP sessions for daemon shutdown.
    ///
    /// # Errors
    /// Returns [`CliError`] when the live ACP registry cannot be drained
    /// cleanly during daemon shutdown.
    pub fn shutdown_all(&self) -> Result<(), CliError> {
        if sandboxed_from_env() {
            Self::shutdown_all_via_bridge();
            return Ok(());
        }
        let _lifecycle = self.process_lifecycle_guard()?;
        self.state.shutdown_requested.store(true, Ordering::SeqCst);
        let sessions: Vec<_> = self.sessions_guard()?.values().cloned().collect();
        for session in sessions {
            let process_key = session.process_key();
            let pending_permissions = session.disconnect(DisconnectReason::DaemonShutdown, false);
            let snapshot = session.snapshot_with_live_counts();
            self.sync_orchestration_disconnect_best_effort(&snapshot);
            if session.process().logical_session_count() == 0 {
                session.terminate_process(pending_permissions);
                self.remove_process_if_empty(&process_key)?;
            }
        }
        Ok(())
    }

    /// [`Self::shutdown_all`] for callers already on the async runtime.
    ///
    /// The sync version blocks its thread for the whole drain: it takes the
    /// process-lifecycle lock, closes each session over the wire, and waits on
    /// child termination. Called straight from a request handler that stalls a
    /// runtime worker, and the daemon still has a shutdown response to send.
    ///
    /// # Errors
    /// Returns [`CliError`] when the drain fails or its thread panics.
    pub async fn shutdown_all_async(&self) -> Result<(), CliError> {
        let manager = self.clone();
        spawn_blocking(move || manager.shutdown_all())
            .await
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "ACP shutdown task failed: {error}"
                )))
            })?
    }

    pub(in crate::daemon::agent_acp) fn start_requested_after_shutdown(&self) -> bool {
        self.state.shutdown_requested.load(Ordering::SeqCst)
    }

    pub(in crate::daemon::agent_acp) fn disconnect_forwarded_session(
        &self,
        active: &Weak<ActiveAcpSession>,
        reason: DisconnectReason,
    ) -> Result<(), CliError> {
        let Some(session) = active.upgrade() else {
            return Ok(());
        };
        let (snapshot, incidents) = {
            let _lifecycle = self.process_lifecycle_guard()?;
            let before = session.snapshot_with_live_counts();
            if before.status.is_disconnected() {
                return Ok(());
            }
            session.refresh();
            let mut snapshot = session.snapshot_with_live_counts();
            let pending_permissions = if snapshot.status.is_disconnected() {
                0
            } else {
                let pending_permissions = session.disconnect(reason, false);
                snapshot = session.snapshot_with_live_counts();
                pending_permissions
            };
            let process_key = session.process_key();
            let incidents = if let Some(event) = process_incident_from_snapshot(&snapshot) {
                self.process_fault_events_locked(&snapshot, event)?
            } else {
                Vec::new()
            };
            if session.process().logical_session_count() == 0 {
                session.terminate_process(pending_permissions);
                self.remove_process_if_empty(&process_key)?;
            }
            (snapshot, incidents)
        };
        self.sync_orchestration_disconnect_best_effort(&snapshot);
        for incident in incidents {
            let _ = self.sender().send(incident);
        }
        let payload = serde_json::to_value(&snapshot).unwrap_or_default();
        let _ = self.sender().send(StreamEvent {
            event: "acp_agent_disconnected".to_string(),
            recorded_at: utc_now(),
            session_id: Some(snapshot.session_id),
            payload,
        });
        Ok(())
    }

    /// Count ACP sessions that are still live after a refresh pass.
    ///
    /// # Errors
    /// Returns [`CliError`] when the sandbox bridge inspect call fails.
    ///
    pub fn count_live_sessions(&self) -> Result<usize, CliError> {
        if sandboxed_from_env() {
            return Self::live_session_count_via_bridge();
        }
        let sessions: Vec<_> = self.sessions_guard()?.values().cloned().collect();
        let mut live = 0;
        for session in sessions {
            if !self
                .refresh_session_snapshot(&session)?
                .status
                .is_disconnected()
            {
                live += 1;
            }
        }
        Ok(live)
    }

    pub(super) fn refresh_session_snapshot(
        &self,
        session: &Arc<ActiveAcpSession>,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let (before_status, after, incidents, disconnected) = {
            let _lifecycle = self.process_lifecycle_guard()?;
            let before_status = session.current_status();
            if before_status.is_disconnected() {
                return Ok(session.snapshot_with_live_counts());
            }
            session.refresh();
            let after = session.snapshot_with_live_counts();
            let disconnected = after.status.is_disconnected();
            let incidents =
                if disconnected && let Some(event) = process_incident_from_snapshot(&after) {
                    self.process_fault_events_locked(&after, event)?
                } else {
                    Vec::new()
                };
            (before_status, after, incidents, disconnected)
        };
        if !disconnected && after.status != before_status {
            self.sync_orchestration_runtime_status_best_effort(&after);
        }
        if disconnected {
            self.sync_orchestration_disconnect_best_effort(&after);
        }
        for event in incidents {
            let _ = self.sender().send(event);
        }
        Ok(after)
    }
}
