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
    ActiveAcpProcess, ActiveAcpSession, ActiveAcpTasks, SharedStderrTail, spawn_event_forwarder,
    spawn_protocol_disconnect_forwarder, spawn_watchdog_forwarder,
};
use super::manager::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest, PERMISSION_RESPONSE_DEADLINE,
    process_fault_policy_enabled, process_pooling_disabled,
};
use super::permission_bridge::PermissionBridgeHandle;
use super::pool_key::AcpProcessPoolKey;
use super::prompt_gate::{PromptGate, PromptOwner, prompt_text};
use super::protocol::{SpawnProtocolInput, spawn_protocol_task};

impl AcpAgentManagerHandle {
    #[cfg(test)]
    pub(super) fn start_descriptor(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.start_descriptor_with_pooling_disabled(session_id, request, descriptor, false)
    }

    pub(in crate::daemon::agent_acp) fn start_descriptor_with_pooling_disabled(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
        disable_pooling: bool,
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
        if process_fault_policy_enabled() {
            self.ensure_process_key_start_allowed(process_key.as_str())?;
        }
        let process_key = if disable_pooling || process_pooling_disabled() {
            format!("{}:isolated:{acp_id}", process_key.as_str())
        } else {
            process_key.as_str().to_string()
        };
        let input = DescriptorStartInput {
            acp_id: &acp_id,
            session_id,
            request,
            descriptor,
            project_dir: &project_dir,
            process_key: &process_key,
        };
        let _lifecycle = self
            .state
            .process_lifecycle
            .lock()
            .expect("ACP process lifecycle lock");
        if let Some(snapshot) = self.try_start_reused_session(input)? {
            return Ok(snapshot);
        }
        self.start_new_process_session(input, &spawn)
    }

    fn try_start_reused_session(
        &self,
        input: DescriptorStartInput<'_>,
    ) -> Result<Option<AcpAgentSnapshot>, CliError> {
        let Some(existing) = self.reusable_session_for_process_key(input.process_key) else {
            return Ok(None);
        };
        if let Some(prompt) = prompt_text(input.request.prompt.as_deref()) {
            existing.prompt_protocol_session(
                input.acp_id,
                input.session_id,
                input.project_dir.to_path_buf(),
                prompt,
            )
        } else {
            existing.attach_protocol_session(
                input.acp_id,
                input.session_id,
                input.project_dir.to_path_buf(),
            )
        }
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "attach reused ACP session '{}': {error}",
                input.descriptor.id
            ))
        })?;
        let snapshot = reused_snapshot(ReusedSnapshotInput {
            acp_id: input.acp_id,
            session_id: input.session_id,
            request: input.request,
            descriptor: input.descriptor,
            source: &existing.snapshot_with_live_counts(),
            project_dir: input.project_dir,
            permission_log_path: input
                .request
                .record_permissions
                .then(|| recording_log_path_for_session(input.session_id)),
        });
        let permissions = PermissionBridgeHandle::spawn(
            input.acp_id.to_string(),
            input.session_id.to_string(),
            self.sender(),
        );
        let active = Arc::new(ActiveAcpSession::new(
            snapshot.clone(),
            permissions,
            existing.process(),
        ));
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .insert(input.acp_id.to_string(), active);
        self.broadcast("acp_agent_started", &snapshot);
        Ok(Some(snapshot))
    }

    fn start_new_process_session(
        &self,
        input: DescriptorStartInput<'_>,
        spawn: &SpawnConfig,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let mut child = spawn.spawn().map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "spawn ACP agent '{}': {error}",
                input.descriptor.id
            ))
        })?;
        let stderr_tail = SharedStderrTail::spawn(child.stderr.take());
        let supervisor = Arc::new(AcpSessionSupervisor::new(
            &child,
            SupervisionConfig::default()
                .with_prompt_timeout(input.descriptor.prompt_timeout_seconds),
        ));
        let prompt_gate = PromptGate::default();
        let initial_prompt_lease = prompt_text(input.request.prompt.as_deref())
            .map(|_| {
                prompt_gate
                    .acquire(PromptOwner::new(input.acp_id, input.session_id))
                    .map_err(|error| CliErrorKind::workflow_io(error.message()))
            })
            .transpose()?;
        let permissions = PermissionBridgeHandle::spawn(
            input.acp_id.to_string(),
            input.session_id.to_string(),
            self.sender(),
        );
        let permission_log_path = input
            .request
            .record_permissions
            .then(|| recording_log_path_for_session(input.session_id));
        let permission_mode = permission_log_path.clone().map_or_else(
            || permissions.mode(PERMISSION_RESPONSE_DEADLINE),
            |log_path| PermissionMode::Recording { log_path },
        );
        let protocol = spawn_protocol_task(
            &mut child,
            SpawnProtocolInput {
                request: input.request,
                acp_id: input.acp_id,
                session_id: input.session_id,
                agent_name: input.descriptor.display_name.clone(),
                project_dir: input.project_dir.to_path_buf(),
                supervisor: &supervisor,
                permission_mode,
                initial_prompt_lease,
            },
        )
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "attach ACP protocol for '{}': {error}",
                input.descriptor.id
            ))
        })?;
        let event_task = spawn_event_forwarder(self.sender(), protocol.events);
        let snapshot = started_snapshot(StartedSnapshotInput {
            acp_id: input.acp_id,
            session_id: input.session_id,
            request: input.request,
            descriptor: input.descriptor,
            supervisor: &supervisor,
            project_dir: input.project_dir,
            process_key: input.process_key,
            permission_log_path,
        });
        let process = Arc::new(ActiveAcpProcess::new(
            child,
            Arc::clone(&supervisor),
            protocol.handle,
            prompt_gate,
            stderr_tail,
            ActiveAcpTasks {
                protocol: protocol.protocol,
                batcher: protocol.batcher,
                event: event_task,
            },
        ));
        let active = Arc::new(ActiveAcpSession::new(
            snapshot.clone(),
            permissions,
            Arc::clone(&process),
        ));
        active.set_protocol_disconnect_task(spawn_protocol_disconnect_forwarder(
            self.clone(),
            Arc::downgrade(&active),
            protocol.disconnects,
        ));
        active.set_watchdog_task(spawn_watchdog_forwarder(
            self.clone(),
            Arc::downgrade(&active),
            supervisor,
        ));
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .insert(input.acp_id.to_string(), active);
        self.insert_process(input.process_key.to_string(), process);
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

struct StartedSnapshotInput<'a> {
    acp_id: &'a str,
    session_id: &'a str,
    request: &'a AcpAgentStartRequest,
    descriptor: &'a AcpAgentDescriptor,
    supervisor: &'a AcpSessionSupervisor,
    project_dir: &'a Path,
    process_key: &'a str,
    permission_log_path: Option<PathBuf>,
}

#[derive(Clone, Copy)]
struct DescriptorStartInput<'a> {
    acp_id: &'a str,
    session_id: &'a str,
    request: &'a AcpAgentStartRequest,
    descriptor: &'a AcpAgentDescriptor,
    project_dir: &'a Path,
    process_key: &'a str,
}

struct ReusedSnapshotInput<'a> {
    acp_id: &'a str,
    session_id: &'a str,
    request: &'a AcpAgentStartRequest,
    descriptor: &'a AcpAgentDescriptor,
    source: &'a AcpAgentSnapshot,
    project_dir: &'a Path,
    permission_log_path: Option<PathBuf>,
}

fn started_snapshot(input: StartedSnapshotInput<'_>) -> AcpAgentSnapshot {
    let StartedSnapshotInput {
        acp_id,
        session_id,
        request,
        descriptor,
        supervisor,
        project_dir,
        process_key,
        permission_log_path,
    } = input;
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

fn reused_snapshot(input: ReusedSnapshotInput<'_>) -> AcpAgentSnapshot {
    let ReusedSnapshotInput {
        acp_id,
        session_id,
        request,
        descriptor,
        source,
        project_dir,
        permission_log_path,
    } = input;
    let now = utc_now();
    AcpAgentSnapshot {
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: descriptor.id.clone(),
        display_name: descriptor.display_name.clone(),
        status: AgentStatus::Active,
        pid: source.pid,
        pgid: source.pgid,
        project_dir: project_dir.display().to_string(),
        process_key: source.process_key.clone(),
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
