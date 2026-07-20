use std::collections::{BTreeMap, BTreeSet};
#[cfg(feature = "daemon-runtime")]
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

pub(crate) use harness_protocol::managed_agents::acp::{
    AcpAgentInspectResponse, AcpAgentInspectSnapshot, AcpAgentSnapshot, AcpAgentStartRequest,
};
use tokio::sync::broadcast;
use tokio::time::Instant;

use super::active::{ActiveAcpProcess, ActiveAcpSession, process_incident_from_snapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};
use crate::agents::acp::catalog;
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
#[cfg(all(test, feature = "daemon-runtime"))]
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

pub(super) const PERMISSION_RESPONSE_DEADLINE: Duration = Duration::from_mins(5);
const PROCESS_KEY_BACKOFF: Duration = Duration::from_secs(1);

mod locks;
#[cfg(feature = "daemon-runtime")]
mod orchestration;
mod port;
mod process_fault;
mod process_pool;
mod reconcile;
mod send_prompt;
mod session_access;
#[cfg(all(test, feature = "daemon-runtime"))]
mod shutdown_tests;
#[cfg(all(test, feature = "daemon-runtime"))]
mod test_support;
#[cfg(feature = "daemon-runtime")]
use orchestration::DaemonAcpManagerPort;
use port::BridgeAcpManagerPort;
pub(in crate::daemon::agent_acp) use port::{AcpManagerPort, AcpOrchestrationRegistration};
pub(in crate::daemon::agent_acp) use process_fault::process_fault_policy_enabled;
pub(in crate::daemon::agent_acp) use process_pool::process_pooling_disabled;
pub use reconcile::AcpAgentReconcileResponse;
#[cfg(feature = "daemon-runtime")]
pub use session_access::AcpWakePrompt;

#[derive(Clone)]
pub struct AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) state: Arc<AcpAgentManagerState>,
}

pub(in crate::daemon::agent_acp) struct AcpAgentManagerState {
    pub(in crate::daemon::agent_acp) port: Arc<dyn AcpManagerPort>,
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
    /// In-flight wake guard keyed by `(acp_id, signal_id)`.
    ///
    /// Each entry corresponds to a live `acp-wake-<acp_id>` thread issuing a
    /// `session/prompt`. `dispatch_wake_prompt` skips spawning when the key is
    /// already present so a signal storm against one ACP session cannot fan
    /// out unbounded threads. The thread removes its own entry on exit.
    #[cfg(feature = "daemon-runtime")]
    pub(in crate::daemon::agent_acp) wake_in_flight: Mutex<BTreeSet<(String, String)>>,
}

impl AcpAgentManagerHandle {
    #[cfg(feature = "daemon-runtime")]
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<std::sync::OnceLock<Arc<Mutex<crate::daemon::db::DaemonDb>>>>,
    ) -> Self {
        Self::new_with_async_db(sender, db, Arc::new(OnceLock::new()))
    }

    #[cfg(feature = "daemon-runtime")]
    #[must_use]
    pub(crate) fn new_with_async_db(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<std::sync::OnceLock<Arc<Mutex<crate::daemon::db::DaemonDb>>>>,
        async_db: Arc<std::sync::OnceLock<Arc<crate::daemon::db::AsyncDaemonDb>>>,
    ) -> Self {
        Self::with_port(Arc::new(DaemonAcpManagerPort::new(sender, db, async_db)))
    }

    #[must_use]
    pub(crate) fn new_bridge(sender: broadcast::Sender<StreamEvent>) -> Self {
        Self::with_port(Arc::new(BridgeAcpManagerPort::new(sender)))
    }

    fn with_port(port: Arc<dyn AcpManagerPort>) -> Self {
        Self {
            state: Arc::new(AcpAgentManagerState {
                port,
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
                #[cfg(feature = "daemon-runtime")]
                wake_in_flight: Mutex::new(BTreeSet::new()),
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
        if crate::daemon::sandboxed_from_env() {
            return self.start_via_bridge_with_pooling_disabled(
                session_id,
                request,
                disable_pooling,
            );
        }
        #[cfg(feature = "daemon-runtime")]
        let openrouter_token = if descriptor.id.as_str() == "openrouter" {
            crate::daemon::state::task_board_openrouter_token()
        } else {
            None
        };
        #[cfg(not(feature = "daemon-runtime"))]
        let openrouter_token: Option<String> = None;
        self.start_descriptor_with_pooling_and_openrouter_token(
            session_id,
            request,
            descriptor,
            disable_pooling,
            openrouter_token.as_deref(),
        )
    }

    pub(in crate::daemon) fn start_with_bridge_openrouter_token(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        disable_pooling: bool,
        openrouter_token: Option<&str>,
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
        self.start_descriptor_with_pooling_and_openrouter_token(
            session_id,
            request,
            descriptor,
            disable_pooling,
            openrouter_token,
        )
    }

    /// List ACP sessions for a Harness session.
    ///
    /// # Errors
    /// Returns [`CliError`] when a live refresh fails.
    pub fn list(&self, session_id: &str) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        if crate::daemon::sandboxed_from_env() {
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
        if crate::daemon::sandboxed_from_env() {
            return Ok(self.inspect_via_bridge(session_id));
        }
        let sessions = self
            .sessions_guard()?
            .values()
            .filter(|session| session_id.is_none_or(|id| session.session_id_matches(id)))
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
            daemon_perceived_now: Some(utc_now()),
            available: true,
            issue_message: None,
        })
    }

    /// Load one ACP session snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn get(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if crate::daemon::sandboxed_from_env() {
            return self.get_via_bridge(acp_id);
        }
        let session = self.session(acp_id)?;
        self.refresh_session_snapshot(&session)
    }

    /// Ask the agent to log out via the ACP `logout` method. Gated on the
    /// agent advertising the `auth.logout` capability at initialize.
    ///
    /// # Errors
    /// Returns [`CliError`] when the daemon is sandboxed, the session is
    /// unknown, the capability is missing, or the agent rejects the call.
    pub fn logout(&self, acp_id: &str) -> Result<(), CliError> {
        if crate::daemon::sandboxed_from_env() {
            return Err(CliErrorKind::workflow_io(
                "ACP logout is not available from a sandboxed daemon".to_string(),
            )
            .into());
        }
        let session = self.session(acp_id)?;
        session.logout().map_err(|error| {
            CliErrorKind::workflow_io(format!("ACP logout for '{acp_id}': {error}")).into()
        })
    }

    /// Stop an ACP session and fail every pending permission with daemon shutdown.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if crate::daemon::sandboxed_from_env() {
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
        if crate::daemon::sandboxed_from_env() {
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
        if crate::daemon::sandboxed_from_env() {
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

#[cfg(all(test, feature = "daemon-runtime"))]
mod disconnect_tests;
#[cfg(all(test, feature = "daemon-runtime"))]
mod lock_recovery_tests;
#[cfg(all(test, feature = "daemon-runtime"))]
mod multiplexing_fault_tests;
#[cfg(all(test, feature = "daemon-runtime"))]
mod multiplexing_tests;
#[cfg(all(test, feature = "daemon-runtime"))]
mod tests;
