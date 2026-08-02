use std::collections::{BTreeMap, BTreeSet};
#[cfg(feature = "daemon-runtime")]
use std::sync::OnceLock;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(crate) use harness_protocol::managed_agents::acp::{
    AcpAgentInspectResponse, AcpAgentInspectSnapshot, AcpAgentSessionState, AcpAgentSnapshot,
    AcpAgentStartRequest, AcpSessionListPage,
};
use tokio::sync::broadcast;
use tokio::time::Instant;

use super::active::{ActiveAcpProcess, ActiveAcpSession};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};
use crate::agents::acp::catalog;
#[cfg(all(test, feature = "daemon-runtime"))]
use crate::agents::kind::DisconnectReason;
#[cfg(feature = "daemon-runtime")]
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::sandboxed_from_env;
#[cfg(feature = "daemon-runtime")]
use crate::daemon::state::task_board_openrouter_token;
use crate::feature_flags;
#[cfg(all(test, feature = "daemon-runtime"))]
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

pub(super) const PERMISSION_RESPONSE_DEADLINE: Duration = Duration::from_mins(5);
const PROCESS_KEY_BACKOFF: Duration = Duration::from_secs(1);

mod agent_sessions;
mod lifecycle;
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
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    ) -> Self {
        Self::new_with_async_db(sender, db, Arc::new(OnceLock::new()))
    }

    #[cfg(feature = "daemon-runtime")]
    #[must_use]
    pub(crate) fn new_with_async_db(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
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

    #[cfg(feature = "daemon-runtime")]
    pub(in crate::daemon::agent_acp) fn runtime_session_id(
        &self,
        session_id: &str,
        acp_id: &str,
    ) -> Result<Option<String>, CliError> {
        self.state.port.runtime_session_id(session_id, acp_id)
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
        if sandboxed_from_env() {
            return self.start_via_bridge_with_pooling_disabled(
                session_id,
                request,
                disable_pooling,
            );
        }
        #[cfg(feature = "daemon-runtime")]
        let openrouter_token = if descriptor.id.as_str() == "openrouter" {
            task_board_openrouter_token()
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
        if sandboxed_from_env() {
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
        if sandboxed_from_env() {
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

    /// Read the last live state one ACP turn reported, including a session
    /// whose process has already gone.
    ///
    /// [`inspect`](Self::inspect) drops disconnected sessions, so a turn that
    /// failed and then detached looks indistinguishable from one that never
    /// reported anything. Reconciliation uses this to settle the run on the
    /// provider's own outcome instead of a generic detachment error.
    ///
    /// Returns `None` when no session carries that id under `session_id`, or
    /// when it never reported any state.
    ///
    /// # Errors
    /// Returns [`CliError`] when the live session registry is unavailable.
    pub fn detached_turn_state(
        &self,
        session_id: &str,
        acp_id: &str,
    ) -> Result<Option<AcpAgentSessionState>, CliError> {
        if sandboxed_from_env() {
            return Ok(self.detached_turn_state_via_bridge(session_id, acp_id));
        }
        Ok(self
            .sessions_guard()?
            .get(acp_id)
            .filter(|session| session.session_id_matches(session_id))
            .and_then(|session| session.last_session_state()))
    }

    /// Load one ACP session snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn get(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if sandboxed_from_env() {
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
        if sandboxed_from_env() {
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
