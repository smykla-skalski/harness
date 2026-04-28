use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::agents::acp::connection::SpawnConfig;
use crate::agents::acp::supervision::{AcpSessionSupervisor, SupervisionConfig};
use crate::agents::kind::DisconnectReason;
use crate::daemon::db::DaemonDb;
use crate::daemon::index;
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::active::{ActiveAcpSession, ActiveAcpTasks, SharedStderrTail, spawn_event_forwarder};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision, PermissionBridgeHandle};
use super::protocol::spawn_protocol_task;

const PERMISSION_RESPONSE_DEADLINE: Duration = Duration::from_mins(5);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentStartRequest {
    #[serde(alias = "agent_id")]
    pub agent: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
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
    pub pending_permissions: usize,
    pub permission_queue_depth: usize,
    pub pending_permission_batches: Vec<AcpPermissionBatch>,
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
    pub uptime_ms: u64,
    pub last_update_at: String,
    pub last_client_call_at: Option<String>,
    pub watchdog_state: String,
    pub pending_permissions: usize,
    pub terminal_count: usize,
    pub prompt_deadline_remaining_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentInspectResponse {
    pub agents: Vec<AcpAgentInspectSnapshot>,
}

#[derive(Clone)]
pub struct AcpAgentManagerHandle {
    state: Arc<AcpAgentManagerState>,
}

struct AcpAgentManagerState {
    sender: broadcast::Sender<StreamEvent>,
    db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    sessions: Mutex<BTreeMap<String, Arc<ActiveAcpSession>>>,
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
        self.start_descriptor(session_id, request, descriptor)
    }

    pub(crate) fn start_descriptor(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let project_dir = self.resolve_project_dir(session_id, request.project_dir.as_deref())?;
        let acp_id = format!("agent-acp-{}", Uuid::new_v4());
        let spawn = SpawnConfig {
            command: descriptor.launch_command.clone(),
            args: descriptor.launch_args.clone(),
            env_passthrough: descriptor.env_passthrough.clone(),
            working_dir: project_dir.clone(),
        };
        let mut child = spawn.spawn().map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn ACP agent '{}': {error}", descriptor.id))
        })?;

        let stderr_tail = SharedStderrTail::spawn(child.stderr.take());
        let supervisor = Arc::new(AcpSessionSupervisor::new(
            &child,
            SupervisionConfig::default().with_prompt_timeout(descriptor.prompt_timeout_seconds),
        ));
        let permissions =
            PermissionBridgeHandle::spawn(acp_id.clone(), session_id.to_string(), self.sender());
        let permission_mode = permissions.mode(PERMISSION_RESPONSE_DEADLINE);
        let (events, receive_task, batcher_task) = spawn_protocol_task(
            &mut child,
            request,
            session_id.to_string(),
            descriptor.display_name.clone(),
            project_dir.clone(),
            &supervisor,
            permission_mode,
        )
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "attach ACP protocol for '{}': {error}",
                descriptor.id
            ))
        })?;
        let event_task = spawn_event_forwarder(
            self.sender(),
            acp_id.clone(),
            session_id.to_string(),
            events,
        );

        let now = utc_now();
        let snapshot = AcpAgentSnapshot {
            acp_id: acp_id.clone(),
            session_id: session_id.to_string(),
            agent_id: descriptor.id.clone(),
            display_name: descriptor.display_name.clone(),
            status: AgentStatus::Active,
            pid: supervisor.pid(),
            pgid: supervisor.pgid(),
            project_dir: project_dir.display().to_string(),
            pending_permissions: 0,
            permission_queue_depth: 0,
            pending_permission_batches: Vec::new(),
            terminal_count: 0,
            created_at: now.clone(),
            updated_at: now,
        };
        let active = Arc::new(ActiveAcpSession::new(
            snapshot.clone(),
            child,
            supervisor,
            permissions,
            stderr_tail,
            ActiveAcpTasks {
                protocol: receive_task,
                batcher: batcher_task,
                event: event_task,
            },
        ));
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .insert(acp_id, active);
        self.broadcast("acp_agent_started", &snapshot);
        Ok(snapshot)
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
        let sessions = self.sessions_for(session_id);
        let mut snapshots = Vec::with_capacity(sessions.len());
        for session in sessions {
            session.refresh();
            snapshots.push(session.snapshot_with_live_counts());
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
                session.refresh();
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
        let session = self.session(acp_id)?;
        session.refresh();
        Ok(session.snapshot_with_live_counts())
    }

    /// Stop an ACP session and fail every pending permission with daemon shutdown.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown.
    pub fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        let session = self.session(acp_id)?;
        let pending_permissions = session.disconnect(DisconnectReason::UserCancelled);
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
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_count())
    }

    #[must_use]
    pub fn pending_permission_batches(&self, acp_id: &str) -> Option<Vec<AcpPermissionBatch>> {
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_batches())
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

    fn sender(&self) -> broadcast::Sender<StreamEvent> {
        self.state.sender.clone()
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn broadcast(&self, event: &str, payload: &impl Serialize) {
        let Some(stream_event) = stream_event(event, payload) else {
            tracing::warn!(event, "failed to serialize ACP manager event");
            return;
        };
        let _ = self.state.sender.send(stream_event);
    }

    fn resolve_project_dir(
        &self,
        session_id: &str,
        requested: Option<&str>,
    ) -> Result<PathBuf, CliError> {
        if let Some(path) = requested.filter(|value| !value.trim().is_empty()) {
            return Ok(PathBuf::from(path));
        }
        if let Some(path) = self.project_dir_from_db(session_id)? {
            return Ok(PathBuf::from(path));
        }
        let resolved = index::resolve_session(session_id)?;
        Ok(preferred_project_dir(
            &resolved.state.worktree_path,
            resolved.project.project_dir.as_deref(),
            resolved.project.repository_root.as_deref(),
            &resolved.project.context_root,
        ))
    }

    fn project_dir_from_db(&self, session_id: &str) -> Result<Option<String>, CliError> {
        let Some(db) = self.state.db.get() else {
            return Ok(None);
        };
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        db.project_dir_for_session(session_id)
    }
}

fn stream_event(event: &str, payload: &impl Serialize) -> Option<StreamEvent> {
    let payload = serde_json::to_value(payload).ok()?;
    let session_id = payload
        .get("session_id")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned);
    Some(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id,
        payload,
    })
}

fn preferred_project_dir(
    worktree_path: &Path,
    project_dir: Option<&Path>,
    repository_root: Option<&Path>,
    context_root: &Path,
) -> PathBuf {
    if worktree_path.as_os_str().is_empty() {
        project_dir
            .or(repository_root)
            .unwrap_or(context_root)
            .to_path_buf()
    } else {
        worktree_path.to_path_buf()
    }
}

#[cfg(test)]
mod tests;
