use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use super::active::{ActiveAcpSession, process_incident_from_snapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};
use crate::agents::acp::catalog;
use crate::agents::kind::DisconnectReason;
use crate::daemon::db::DaemonDb;
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
use crate::session::types::AgentStatus;

pub(super) const PERMISSION_RESPONSE_DEADLINE: Duration = Duration::from_mins(5);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentStartRequest {
    #[serde(alias = "agent_id")]
    pub agent: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub record_permissions: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AcpAgentSnapshot {
    pub acp_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub display_name: String,
    pub status: AgentStatus,
    pub pid: u32,
    pub pgid: i32,
    pub project_dir: String,
    pub process_key: String,
    pub pending_permissions: usize,
    pub permission_queue_depth: usize,
    pub pending_permission_batches: Vec<AcpPermissionBatch>,
    #[serde(default)]
    pub permission_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_log_path: Option<String>,
    pub terminal_count: usize,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentInspectSnapshot {
    pub acp_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub display_name: String,
    pub pid: u32,
    pub pgid: i32,
    #[serde(default)]
    pub process_key: String,
    pub uptime_ms: u64,
    pub last_update_at: String,
    pub last_client_call_at: Option<String>,
    pub watchdog_state: String,
    #[serde(default)]
    pub permission_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_log_path: Option<String>,
    pub pending_permissions: usize,
    #[serde(default)]
    pub permission_queue_depth: usize,
    pub terminal_count: usize,
    pub prompt_deadline_remaining_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentInspectResponse {
    pub agents: Vec<AcpAgentInspectSnapshot>,
}

#[derive(Clone)]
pub struct AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) state: Arc<AcpAgentManagerState>,
}

pub(in crate::daemon::agent_acp) struct AcpAgentManagerState {
    pub(in crate::daemon::agent_acp) sender: broadcast::Sender<StreamEvent>,
    pub(in crate::daemon::agent_acp) db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub(in crate::daemon::agent_acp) sessions: Mutex<BTreeMap<String, Arc<ActiveAcpSession>>>,
    pub(in crate::daemon::agent_acp) sandbox_event_poller_running: AtomicBool,
    pub(in crate::daemon::agent_acp) sandbox_event_cursor: Mutex<Option<u64>>,
    pub(in crate::daemon::agent_acp) sandbox_event_epoch: Mutex<Option<String>>,
    pub(in crate::daemon::agent_acp) sandbox_event_continuity: Mutex<Option<u64>>,
    pub(in crate::daemon::agent_acp) sandbox_known_sessions: Mutex<BTreeSet<String>>,
}

impl AcpAgentManagerHandle {
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    ) -> Self {
        Self {
            state: Arc::new(AcpAgentManagerState {
                sender,
                db,
                sessions: Mutex::new(BTreeMap::new()),
                sandbox_event_poller_running: AtomicBool::new(false),
                sandbox_event_cursor: Mutex::new(None),
                sandbox_event_epoch: Mutex::new(None),
                sandbox_event_continuity: Mutex::new(None),
                sandbox_known_sessions: Mutex::new(BTreeSet::new()),
            }),
        }
    }

    /// Start an ACP agent session using a built-in descriptor.
    ///
    /// # Errors
    /// Returns [`CliError`] if ACP is disabled, the descriptor is unknown, the
    /// project cannot be resolved, or the child process cannot be spawned.
    pub fn start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError> {
        if !feature_flags::acp_enabled_from_env() {
            return Err(CliErrorKind::workflow_parse(format!(
                "ACP managed agents are disabled; set {}=1 to enable",
                feature_flags::ACP_ENV
            ))
            .into());
        }
        let descriptor = catalog::find_builtin(request.agent.trim()).ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "unknown ACP agent '{}'",
                request.agent
            )))
        })?;
        if service::sandboxed_from_env() {
            return self.start_via_bridge(session_id, request);
        }
        self.start_descriptor(session_id, request, descriptor)
    }

    /// Resolve a pending ACP permission batch and return the updated snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] when the ACP session or permission batch is unknown.
    pub fn resolve_permission_batch(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, CliError> {
        if service::sandboxed_from_env() {
            return self.resolve_permission_batch_via_bridge(acp_id, batch_id, decision);
        }
        let session = self.session(acp_id)?;
        if !session.resolve_permission_batch(batch_id, decision) {
            return Err(CliErrorKind::session_not_active(format!(
                "ACP permission batch '{batch_id}' not found"
            ))
            .into());
        }
        let snapshot = session.snapshot_with_live_counts();
        self.broadcast("acp_permission_batch_resolved", &snapshot);
        Ok(snapshot)
    }

    /// List ACP sessions for a Harness session.
    ///
    /// # Errors
    /// Returns [`CliError`] when a live refresh fails.
    pub fn list(&self, session_id: &str) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        if service::sandboxed_from_env() {
            return self.list_via_bridge(session_id);
        }
        let sessions = self.sessions_for(session_id);
        let mut snapshots = Vec::with_capacity(sessions.len());
        for session in sessions {
            snapshots.push(self.refresh_session_snapshot(&session));
        }
        snapshots.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.acp_id.cmp(&b.acp_id))
        });
        Ok(snapshots)
    }

    /// Inspect live ACP sessions without starting or stopping anything.
    ///
    /// # Panics
    /// Panics if the ACP sessions mutex is poisoned.
    #[must_use]
    pub fn inspect(&self, session_id: Option<&str>) -> AcpAgentInspectResponse {
        if service::sandboxed_from_env() {
            return self.inspect_via_bridge(session_id);
        }
        let sessions = self
            .state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .filter(|session| session_id.is_none_or(|id| session.session_id() == id))
            .cloned()
            .collect::<Vec<_>>();
        let mut agents = sessions
            .into_iter()
            .map(|session| {
                self.refresh_session_snapshot(&session);
                session.inspect_snapshot()
            })
            .collect::<Vec<_>>();
        agents.sort_by(|a, b| {
            b.last_update_at
                .cmp(&a.last_update_at)
                .then_with(|| a.acp_id.cmp(&b.acp_id))
        });
        AcpAgentInspectResponse { agents }
    }

    /// Load one ACP session snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn get(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if service::sandboxed_from_env() {
            return self.get_via_bridge(acp_id);
        }
        let session = self.session(acp_id)?;
        Ok(self.refresh_session_snapshot(&session))
    }

    /// Stop an ACP session and fail every pending permission with daemon shutdown.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if service::sandboxed_from_env() {
            return self.stop_via_bridge(acp_id);
        }
        let session = self.session(acp_id)?;
        let pending_permissions = session.disconnect(DisconnectReason::SessionStopped);
        session.kill_child(pending_permissions);
        let snapshot = session.snapshot_with_live_counts();
        self.broadcast("acp_agent_stopped", &snapshot);
        Ok(snapshot)
    }

    /// Fail all live ACP sessions for daemon shutdown.
    ///
    /// # Panics
    /// Panics if the ACP sessions mutex is poisoned.
    pub fn shutdown_all(&self) {
        if service::sandboxed_from_env() {
            self.shutdown_all_via_bridge();
            return;
        }
        let sessions: Vec<_> = self
            .state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .cloned()
            .collect();
        for session in sessions {
            let pending_permissions = session.disconnect(DisconnectReason::DaemonShutdown);
            session.kill_child(pending_permissions);
        }
    }

    #[must_use]
    pub fn pending_permission_count(&self, acp_id: &str) -> Option<usize> {
        if service::sandboxed_from_env() {
            return self.pending_permission_count_via_bridge(acp_id);
        }
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_count())
    }

    #[must_use]
    pub fn pending_permission_batches(&self, acp_id: &str) -> Option<Vec<AcpPermissionBatch>> {
        if service::sandboxed_from_env() {
            return self.pending_permission_batches_via_bridge(acp_id);
        }
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_batches())
    }

    #[must_use]
    pub fn count_live_sessions(&self) -> Result<usize, CliError> {
        if service::sandboxed_from_env() {
            return self.live_session_count_via_bridge();
        }
        Ok(self
            .state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .filter(|session| {
                !self
                    .refresh_session_snapshot(session)
                    .status
                    .is_disconnected()
            })
            .count())
    }

    fn refresh_session_snapshot(&self, session: &Arc<ActiveAcpSession>) -> AcpAgentSnapshot {
        let before = session.snapshot_with_live_counts();
        session.refresh();
        let after = session.snapshot_with_live_counts();
        if !before.status.is_disconnected() && after.status.is_disconnected()
            && let Some(event) = process_incident_from_snapshot(&after)
        {
            let _ = self.state.sender.send(event);
        }
        after
    }

    fn session(&self, acp_id: &str) -> Result<Arc<ActiveAcpSession>, CliError> {
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .get(acp_id)
            .cloned()
            .ok_or_else(|| {
                CliErrorKind::session_not_active(format!("ACP session '{acp_id}' not found")).into()
            })
    }

    fn sessions_for(&self, session_id: &str) -> Vec<Arc<ActiveAcpSession>> {
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .filter(|session| session.session_id() == session_id)
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests;
