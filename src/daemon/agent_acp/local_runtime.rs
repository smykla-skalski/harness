use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde::Serialize;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::agents::acp::catalog::AcpAgentDescriptor;
use crate::agents::acp::connection::SpawnConfig;
use crate::agents::acp::permission::{PermissionMode, recording_log_path_for_session};
use crate::agents::acp::supervision::{AcpSessionSupervisor, SupervisionConfig};
use crate::daemon::index;
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::active::{
    ActiveAcpSession, ActiveAcpTasks, SharedStderrTail, spawn_event_forwarder,
    spawn_protocol_disconnect_forwarder, spawn_watchdog_forwarder,
};
use super::manager::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest, PERMISSION_RESPONSE_DEADLINE,
};
use super::permission_bridge::PermissionBridgeHandle;
use super::pool_key::AcpProcessPoolKey;
use super::protocol::spawn_protocol_task;

impl AcpAgentManagerHandle {
    pub(super) fn start_descriptor(
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
        let process_key = AcpProcessPoolKey::from_spawn_inputs(
            descriptor,
            request,
            session_id,
            &spawn,
            &project_dir,
        );
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
        let permission_log_path = request
            .record_permissions
            .then(|| recording_log_path_for_session(session_id));
        let permission_mode = permission_log_path.clone().map_or_else(
            || permissions.mode(PERMISSION_RESPONSE_DEADLINE),
            |log_path| PermissionMode::Recording { log_path },
        );
        let protocol = spawn_protocol_task(
            &mut child,
            request,
            session_id,
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
            protocol.events,
        );
        let snapshot = started_snapshot(
            &acp_id,
            session_id,
            request,
            descriptor,
            &supervisor,
            &project_dir,
            process_key.as_str(),
            permission_log_path,
        );
        let active = Arc::new(ActiveAcpSession::new(
            snapshot.clone(),
            child,
            Arc::clone(&supervisor),
            permissions,
            protocol.cancel,
            stderr_tail,
            ActiveAcpTasks {
                protocol: protocol.protocol,
                batcher: protocol.batcher,
                event: event_task,
            },
        ));
        active.set_protocol_disconnect_task(spawn_protocol_disconnect_forwarder(
            self.sender(),
            Arc::downgrade(&active),
            protocol.disconnects,
        ));
        active.set_watchdog_task(spawn_watchdog_forwarder(
            self.sender(),
            Arc::downgrade(&active),
            supervisor,
        ));
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .insert(acp_id, active);
        self.broadcast("acp_agent_started", &snapshot);
        Ok(snapshot)
    }

    pub(super) fn sender(&self) -> broadcast::Sender<StreamEvent> {
        self.state.sender.clone()
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn broadcast_event(
        stream_event: Option<StreamEvent>,
        event: &str,
        sender: &broadcast::Sender<StreamEvent>,
    ) {
        stream_event.map_or_else(
            || tracing::warn!(event, "failed to serialize ACP manager event"),
            |stream_event| {
                let _ = sender.send(stream_event);
            },
        );
    }

    pub(super) fn broadcast(&self, event: &str, payload: &impl Serialize) {
        Self::broadcast_event(stream_event(event, payload), event, &self.state.sender);
    }

    pub(super) fn resolve_project_dir(
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

    pub(super) fn project_dir_from_db(&self, session_id: &str) -> Result<Option<String>, CliError> {
        let Some(db) = self.state.db.get() else {
            return Ok(None);
        };
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        db.project_dir_for_session(session_id)
    }

    pub(super) fn sandbox_event_cursor(&self) -> Option<u64> {
        *self
            .state
            .sandbox_event_cursor
            .lock()
            .expect("ACP sandbox cursor lock")
    }

    pub(super) fn set_sandbox_event_cursor(&self, cursor: Option<u64>) {
        *self
            .state
            .sandbox_event_cursor
            .lock()
            .expect("ACP sandbox cursor lock") = cursor;
    }

    pub(super) fn sandbox_event_epoch(&self) -> Option<String> {
        self.state
            .sandbox_event_epoch
            .lock()
            .expect("ACP sandbox epoch lock")
            .clone()
    }

    pub(super) fn set_sandbox_event_epoch(&self, epoch: Option<String>) {
        *self
            .state
            .sandbox_event_epoch
            .lock()
            .expect("ACP sandbox epoch lock") = epoch;
    }

    pub(super) fn sandbox_event_continuity(&self) -> Option<u64> {
        *self
            .state
            .sandbox_event_continuity
            .lock()
            .expect("ACP sandbox continuity lock")
    }

    pub(super) fn set_sandbox_event_continuity(&self, continuity: Option<u64>) {
        *self
            .state
            .sandbox_event_continuity
            .lock()
            .expect("ACP sandbox continuity lock") = continuity;
    }

    pub(super) fn sandbox_known_sessions(&self) -> BTreeSet<String> {
        self.state
            .sandbox_known_sessions
            .lock()
            .expect("ACP sandbox known sessions lock")
            .clone()
    }

    pub(super) fn set_sandbox_known_sessions(&self, sessions: BTreeSet<String>) {
        *self
            .state
            .sandbox_known_sessions
            .lock()
            .expect("ACP sandbox known sessions lock") = sessions;
    }

    pub(super) fn swap_sandbox_event_poller_running(&self) -> bool {
        self.state
            .sandbox_event_poller_running
            .swap(true, Ordering::SeqCst)
    }

    pub(super) fn clear_sandbox_event_poller_running(&self) {
        self.state
            .sandbox_event_poller_running
            .store(false, Ordering::SeqCst);
    }
}

fn started_snapshot(
    acp_id: &str,
    session_id: &str,
    request: &AcpAgentStartRequest,
    descriptor: &AcpAgentDescriptor,
    supervisor: &AcpSessionSupervisor,
    project_dir: &Path,
    process_key: &str,
    permission_log_path: Option<PathBuf>,
) -> AcpAgentSnapshot {
    let now = utc_now();
    AcpAgentSnapshot {
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: descriptor.id.clone(),
        display_name: descriptor.display_name.clone(),
        status: AgentStatus::Active,
        pid: supervisor.pid(),
        pgid: supervisor.pgid(),
        project_dir: project_dir.display().to_string(),
        process_key: process_key.to_string(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: if request.record_permissions {
            "recording".to_string()
        } else {
            "daemon_bridge".to_string()
        },
        permission_log_path: permission_log_path.map(|path| path.display().to_string()),
        terminal_count: 0,
        created_at: now.clone(),
        updated_at: now,
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
