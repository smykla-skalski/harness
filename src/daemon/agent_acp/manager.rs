use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use super::active::{ActiveAcpProcess, ActiveAcpSession, process_incident_from_snapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};
use crate::agents::acp::catalog;
use crate::agents::kind::DisconnectReason;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
use crate::session::service as orchestration_service;
use crate::session::types::{AgentStatus, SessionRole};
use crate::workspace::utc_now;

pub(super) const PERMISSION_RESPONSE_DEADLINE: Duration = Duration::from_mins(5);
const PROCESS_KEY_BACKOFF: Duration = Duration::from_secs(1);

fn default_acp_role() -> SessionRole {
    SessionRole::Worker
}

const fn default_acp_inspect_available() -> bool {
    true
}

#[derive(Debug, Clone)]
pub(in crate::daemon::agent_acp) struct AcpOrchestrationRegistration {
    pub agent_id: String,
    pub display_name: String,
}

mod locks;
mod orchestration;
mod process_fault;
mod process_pool;
mod reconcile;
mod session_access;
#[cfg(test)]
mod shutdown_tests;
#[cfg(test)]
mod test_support;
pub(in crate::daemon::agent_acp) use process_fault::process_fault_policy_enabled;
pub(in crate::daemon::agent_acp) use process_pool::process_pooling_disabled;
pub use reconcile::AcpAgentReconcileResponse;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentStartRequest {
    #[serde(alias = "agent_id")]
    pub agent: String,
    #[serde(default = "default_acp_role")]
    pub role: SessionRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_role: Option<SessionRole>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona: Option<String>,
    #[serde(default)]
    pub record_permissions: bool,
}

impl Default for AcpAgentStartRequest {
    fn default() -> Self {
        Self {
            agent: String::new(),
            role: default_acp_role(),
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            persona: None,
            record_permissions: false,
        }
    }
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
    #[serde(default = "default_acp_inspect_available")]
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue_message: Option<String>,
}

#[derive(Clone)]
pub struct AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) state: Arc<AcpAgentManagerState>,
}

pub(in crate::daemon::agent_acp) struct AcpAgentManagerState {
    pub(in crate::daemon::agent_acp) sender: broadcast::Sender<StreamEvent>,
    pub(in crate::daemon::agent_acp) db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub(in crate::daemon::agent_acp) async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
    pub(in crate::daemon::agent_acp) process_lifecycle: Mutex<()>,
    pub(in crate::daemon::agent_acp) shutdown_requested: AtomicBool,
    pub(in crate::daemon::agent_acp) sessions: Mutex<BTreeMap<String, Arc<ActiveAcpSession>>>,
    pub(in crate::daemon::agent_acp) processes: Mutex<BTreeMap<String, Arc<ActiveAcpProcess>>>,
    pub(in crate::daemon::agent_acp) sandbox_event_poller_running: AtomicBool,
    pub(in crate::daemon::agent_acp) sandbox_event_cursor: Mutex<Option<u64>>,
    pub(in crate::daemon::agent_acp) sandbox_event_epoch: Mutex<Option<String>>,
    pub(in crate::daemon::agent_acp) sandbox_event_continuity: Mutex<Option<u64>>,
    pub(in crate::daemon::agent_acp) sandbox_known_sessions: Mutex<BTreeSet<String>>,
    pub(in crate::daemon::agent_acp) process_key_failures: Mutex<BTreeMap<String, u32>>,
    pub(in crate::daemon::agent_acp) process_key_backoff_until: Mutex<BTreeMap<String, Instant>>,
    pub(in crate::daemon::agent_acp) quarantined_process_keys: Mutex<BTreeSet<String>>,
}

impl AcpAgentManagerHandle {
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    ) -> Self {
        Self::new_with_async_db(sender, db, Arc::new(OnceLock::new()))
    }

    #[must_use]
    pub(crate) fn new_with_async_db(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
    ) -> Self {
        Self {
            state: Arc::new(AcpAgentManagerState {
                sender,
                db,
                async_db,
                process_lifecycle: Mutex::new(()),
                shutdown_requested: AtomicBool::new(false),
                sessions: Mutex::new(BTreeMap::new()),
                processes: Mutex::new(BTreeMap::new()),
                sandbox_event_poller_running: AtomicBool::new(false),
                sandbox_event_cursor: Mutex::new(None),
                sandbox_event_epoch: Mutex::new(None),
                sandbox_event_continuity: Mutex::new(None),
                sandbox_known_sessions: Mutex::new(BTreeSet::new()),
                process_key_failures: Mutex::new(BTreeMap::new()),
                process_key_backoff_until: Mutex::new(BTreeMap::new()),
                quarantined_process_keys: Mutex::new(BTreeSet::new()),
            }),
        }
    }

    fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        ensure_shared_db(&self.state.db)
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
        self.start_with_pooling_disabled(session_id, request, true)
    }

    pub(crate) fn start_with_pooling_disabled(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        disable_pooling: bool,
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
            return self.start_via_bridge_with_pooling_disabled(
                session_id,
                request,
                disable_pooling,
            );
        }
        self.start_descriptor_with_pooling_disabled(
            session_id,
            request,
            descriptor,
            disable_pooling,
        )
    }

    /// List ACP sessions for a Harness session.
    ///
    /// # Errors
    /// Returns [`CliError`] when a live refresh fails.
    pub fn list(&self, session_id: &str) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        if service::sandboxed_from_env() {
            return self.list_via_bridge(session_id);
        }
        let sessions = self.sessions_for(session_id)?;
        let mut snapshots = Vec::with_capacity(sessions.len());
        for session in sessions {
            let snapshot = self.refresh_session_snapshot(&session)?;
            if !snapshot.status.is_disconnected() {
                snapshots.push(snapshot);
            }
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
    /// # Errors
    /// Returns [`CliError`] when the live session registry is unavailable.
    pub fn inspect(&self, session_id: Option<&str>) -> Result<AcpAgentInspectResponse, CliError> {
        if service::sandboxed_from_env() {
            return Ok(self.inspect_via_bridge(session_id));
        }
        let sessions = self
            .sessions_guard()?
            .values()
            .filter(|session| session_id.is_none_or(|id| session.session_id() == id))
            .cloned()
            .collect::<Vec<_>>();
        let mut agents = Vec::with_capacity(sessions.len());
        for session in sessions {
            let snapshot = self.refresh_session_snapshot(&session)?;
            if snapshot.status.is_disconnected() {
                continue;
            }
            agents.push(session.inspect_snapshot_for(&snapshot));
        }
        agents.sort_by(|a, b| {
            b.last_update_at
                .cmp(&a.last_update_at)
                .then_with(|| a.acp_id.cmp(&b.acp_id))
        });
        Ok(AcpAgentInspectResponse {
            agents,
            available: true,
            issue_message: None,
        })
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
        self.refresh_session_snapshot(&session)
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
        if service::sandboxed_from_env() {
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
            let _ = self.state.sender.send(incident);
        }
        let payload = serde_json::to_value(&snapshot).unwrap_or_default();
        let _ = self.state.sender.send(StreamEvent {
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
        if service::sandboxed_from_env() {
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

    fn refresh_session_snapshot(
        &self,
        session: &Arc<ActiveAcpSession>,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let (after, incidents, disconnected) = {
            let _lifecycle = self.process_lifecycle_guard()?;
            let before = session.snapshot_with_live_counts();
            if before.status.is_disconnected() {
                return Ok(before);
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
            (after, incidents, disconnected)
        };
        if disconnected {
            self.sync_orchestration_disconnect_best_effort(&after);
        }
        for event in incidents {
            let _ = self.state.sender.send(event);
        }
        Ok(after)
    }
}

#[cfg(test)]
mod disconnect_tests;
#[cfg(test)]
mod lock_recovery_tests;
#[cfg(test)]
mod multiplexing_fault_tests;
#[cfg(test)]
mod multiplexing_tests;
#[cfg(test)]
mod tests;
