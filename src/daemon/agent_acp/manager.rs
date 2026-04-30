use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use super::active::{ActiveAcpProcess, ActiveAcpSession, process_incident_from_snapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};
use crate::agents::acp::catalog;
use crate::agents::kind::DisconnectReason;
use crate::daemon::db::DaemonDb;
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
use crate::session::service as orchestration_service;
use crate::session::types::{AgentStatus, ManagedAgentRef, SessionRole};
use crate::workspace::utc_now;

pub(super) const PERMISSION_RESPONSE_DEADLINE: Duration = Duration::from_mins(5);
const PROCESS_KEY_BACKOFF: Duration = Duration::from_secs(1);

fn default_acp_role() -> SessionRole {
    SessionRole::Worker
}

#[derive(Debug, Clone)]
pub(in crate::daemon::agent_acp) struct AcpOrchestrationRegistration {
    pub agent_id: String,
    pub display_name: String,
}

mod process_fault;
mod process_pool;
#[cfg(test)]
mod test_support;
pub(in crate::daemon::agent_acp) use process_fault::process_fault_policy_enabled;
pub(in crate::daemon::agent_acp) use process_pool::process_pooling_disabled;

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
}

#[derive(Clone)]
pub struct AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) state: Arc<AcpAgentManagerState>,
}

pub(in crate::daemon::agent_acp) struct AcpAgentManagerState {
    pub(in crate::daemon::agent_acp) sender: broadcast::Sender<StreamEvent>,
    pub(in crate::daemon::agent_acp) db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub(in crate::daemon::agent_acp) process_lifecycle: Mutex<()>,
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
        Self {
            state: Arc::new(AcpAgentManagerState {
                sender,
                db,
                process_lifecycle: Mutex::new(()),
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

    pub(in crate::daemon::agent_acp) fn register_orchestration_agent(
        &self,
        session_id: &str,
        acp_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &catalog::AcpAgentDescriptor,
        display_name: &str,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        let db =
            self.state.db.get().cloned().ok_or_else(|| {
                CliErrorKind::workflow_io("daemon database unavailable".to_string())
            })?;
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Err(service::session_not_found(session_id));
        };
        let now = utc_now();
        let joined_role =
            orchestration_service::resolve_join_role(&state, request.role, request.fallback_role)?;
        let agent_id = orchestration_service::apply_join_session(
            &mut state,
            display_name,
            &descriptor.id,
            joined_role,
            &request.capabilities,
            None,
            &now,
            request.persona.as_deref(),
            Some(ManagedAgentRef::acp(acp_id)),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            session_id,
            orchestration_service::log_agent_joined(&agent_id, joined_role, &descriptor.id),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(AcpOrchestrationRegistration {
            agent_id,
            display_name: display_name.to_string(),
        })
    }

    pub(in crate::daemon::agent_acp) fn bind_orchestration_runtime_session(
        &self,
        session_id: &str,
        acp_id: &str,
        runtime_name: &str,
        agent_session_id: &str,
    ) -> Result<bool, CliError> {
        let db =
            self.state.db.get().cloned().ok_or_else(|| {
                CliErrorKind::workflow_io("daemon database unavailable".to_string())
            })?;
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        let registered = orchestration_service::apply_register_agent_runtime_session(
            &mut state,
            runtime_name,
            &ManagedAgentRef::acp(acp_id),
            agent_session_id,
            &now,
        )?;
        if !registered {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    pub(in crate::daemon::agent_acp) fn sync_orchestration_disconnect(
        &self,
        snapshot: &AcpAgentSnapshot,
    ) -> Result<bool, CliError> {
        let AgentStatus::Disconnected {
            reason,
            stderr_tail,
        } = &snapshot.status
        else {
            return Ok(false);
        };
        let db =
            self.state.db.get().cloned().ok_or_else(|| {
                CliErrorKind::workflow_io("daemon database unavailable".to_string())
            })?;
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        let Some(mut state) = db.load_session_state_for_mutation(&snapshot.session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        let disconnected = orchestration_service::apply_agent_disconnected_with_reason(
            &mut state,
            &snapshot.agent_id,
            reason.clone(),
            stderr_tail.clone(),
            &now,
        );
        if !disconnected {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(&snapshot.session_id)?
            .ok_or_else(|| service::session_not_found(&snapshot.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            &snapshot.session_id,
            orchestration_service::log_agent_disconnected(
                &snapshot.agent_id,
                disconnect_reason_label(reason),
            ),
            None,
            None,
        ))?;
        db.bump_change(&snapshot.session_id)?;
        db.bump_change("global")?;
        Ok(true)
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
                "permission_batch_stale: ACP permission batch '{batch_id}' is not pending for session '{acp_id}'"
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
    ///
    /// # Panics
    /// Panics if the ACP process lifecycle mutex is poisoned.
    pub fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if service::sandboxed_from_env() {
            return self.stop_via_bridge(acp_id);
        }
        let session = self.session(acp_id)?;
        let _lifecycle = self
            .state
            .process_lifecycle
            .lock()
            .expect("ACP process lifecycle lock");
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
            self.remove_process_if_empty(&process_key);
        }
        let snapshot = session.snapshot_with_live_counts();
        self.sync_orchestration_disconnect_best_effort(&snapshot);
        self.broadcast("acp_agent_stopped", &snapshot);
        Ok(snapshot)
    }

    /// Fail all live ACP sessions for daemon shutdown.
    ///
    /// # Panics
    /// Panics if the ACP sessions mutex is poisoned.
    pub fn shutdown_all(&self) {
        if service::sandboxed_from_env() {
            Self::shutdown_all_via_bridge();
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
            let _lifecycle = self
                .state
                .process_lifecycle
                .lock()
                .expect("ACP process lifecycle lock");
            let process_key = session.process_key();
            let pending_permissions = session.disconnect(DisconnectReason::DaemonShutdown, false);
            let snapshot = session.snapshot_with_live_counts();
            self.sync_orchestration_disconnect_best_effort(&snapshot);
            if session.process().logical_session_count() == 0 {
                session.terminate_process(pending_permissions);
                self.remove_process_if_empty(&process_key);
            }
        }
    }

    pub(in crate::daemon::agent_acp) fn disconnect_forwarded_session(
        &self,
        active: &Weak<ActiveAcpSession>,
        reason: DisconnectReason,
    ) {
        let Some(session) = active.upgrade() else {
            return;
        };
        let (snapshot, incidents) = {
            let _lifecycle = self
                .state
                .process_lifecycle
                .lock()
                .expect("ACP process lifecycle lock");
            session.refresh();
            let pending_permissions = session.disconnect(reason, false);
            let process_key = session.process_key();
            let snapshot = session.snapshot_with_live_counts();
            let incidents = process_incident_from_snapshot(&snapshot)
                .map_or_else(Vec::new, |event| {
                    self.process_fault_events_locked(&snapshot, event)
                });
            if session.process().logical_session_count() == 0 {
                session.terminate_process(pending_permissions);
                self.remove_process_if_empty(&process_key);
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
    }

    #[must_use]
    /// Return the number of pending ACP permission prompts for one ACP session.
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
    /// Return the queued ACP permission batches for one ACP session.
    pub fn pending_permission_batches(&self, acp_id: &str) -> Option<Vec<AcpPermissionBatch>> {
        if service::sandboxed_from_env() {
            return self.pending_permission_batches_via_bridge(acp_id);
        }
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_batches())
    }

    /// Count ACP sessions that are still live after a refresh pass.
    ///
    /// # Errors
    /// Returns [`CliError`] when the sandbox bridge inspect call fails.
    ///
    /// # Panics
    /// Panics if the ACP sessions mutex is poisoned.
    pub fn count_live_sessions(&self) -> Result<usize, CliError> {
        if service::sandboxed_from_env() {
            return Self::live_session_count_via_bridge();
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
        if !before.status.is_disconnected() && after.status.is_disconnected() {
            self.sync_orchestration_disconnect_best_effort(&after);
        }
        if !before.status.is_disconnected()
            && after.status.is_disconnected()
            && let Some(event) = process_incident_from_snapshot(&after)
        {
            for event in self.process_fault_events(&after, event) {
                let _ = self.state.sender.send(event);
            }
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

    pub(in crate::daemon::agent_acp) fn ensure_process_key_start_allowed(
        &self,
        process_key: &str,
    ) -> Result<(), CliError> {
        if let Some(until) = self
            .state
            .process_key_backoff_until
            .lock()
            .expect("ACP process key backoff lock")
            .get(process_key)
            .copied()
            && until > Instant::now()
        {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "ACP process key is in backoff after recent faults: {process_key}"
            ))
            .into());
        }
        if self
            .state
            .quarantined_process_keys
            .lock()
            .expect("ACP quarantined process keys lock")
            .contains(process_key)
        {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "ACP process key is quarantined after repeated faults: {process_key}"
            ))
            .into());
        }
        Ok(())
    }

    fn sync_orchestration_disconnect_best_effort(&self, snapshot: &AcpAgentSnapshot) {
        if let Err(error) = self.sync_orchestration_disconnect(snapshot) {
            tracing::warn!(
                acp_id = %snapshot.acp_id,
                session_id = %snapshot.session_id,
                agent_id = %snapshot.agent_id,
                %error,
                "failed to sync ACP disconnect into session orchestration"
            );
        }
    }
}

fn disconnect_reason_label(reason: &DisconnectReason) -> &'static str {
    match reason {
        DisconnectReason::ProcessExited { .. } => "process_exited",
        DisconnectReason::StdioClosed => "stdio_closed",
        DisconnectReason::TransportClosed => "transport_closed",
        DisconnectReason::InitializeTimeout => "initialize_timeout",
        DisconnectReason::PromptTimeout => "prompt_timeout",
        DisconnectReason::WatchdogFired => "watchdog_fired",
        DisconnectReason::UserCancelled => "user_cancelled",
        DisconnectReason::SessionStopped => "session_stopped",
        DisconnectReason::DaemonShutdown => "daemon_shutdown",
        DisconnectReason::OomKilled => "oom_killed",
        DisconnectReason::Unknown { .. } => "unknown",
    }
}

#[cfg(test)]
mod multiplexing_tests;
#[cfg(test)]
mod tests;
