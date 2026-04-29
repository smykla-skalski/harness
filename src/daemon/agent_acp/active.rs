use std::io::Read;
use std::path::PathBuf;
use std::process::ChildStderr;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread;

use serde::Serialize;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;

use crate::agents::acp::connection::EventBatch;
use crate::agents::acp::supervision::{AcpSessionSupervisor, watchdog_loop};
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::manager::{AcpAgentInspectSnapshot, AcpAgentManagerHandle, AcpAgentSnapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision, PermissionBridgeHandle};

const STDERR_TAIL_LIMIT: usize = 16 * 1024;

mod process;
pub(in crate::daemon::agent_acp) use process::{ActiveAcpProcess, ActiveAcpTasks};

pub(super) struct ActiveAcpSession {
    snapshot: Mutex<AcpAgentSnapshot>,
    permissions: PermissionBridgeHandle,
    process: Arc<ActiveAcpProcess>,
}

#[derive(Clone, Default)]
pub(super) struct SharedStderrTail {
    bytes: Arc<Mutex<Vec<u8>>>,
}

#[derive(Serialize)]
struct AcpProcessIncidentPayload {
    kind: String,
    reason_kind: String,
    process_key: String,
    pid: u32,
    pgid: i32,
    exit_code: Option<i32>,
    exit_signal: Option<i32>,
    restart_applied: bool,
    backoff_applied: bool,
    quarantine_applied: bool,
    stderr_tail: Option<String>,
    affected_logical_session_ids: Vec<String>,
}

impl ActiveAcpSession {
    #[must_use]
    pub(super) fn new(
        snapshot: AcpAgentSnapshot,
        permissions: PermissionBridgeHandle,
        process: Arc<ActiveAcpProcess>,
    ) -> Self {
        process.add_logical_session(&snapshot.acp_id);
        Self {
            snapshot: Mutex::new(snapshot),
            permissions,
            process,
        }
    }

    pub(super) fn process_key(&self) -> String {
        self.snapshot
            .lock()
            .expect("ACP snapshot lock")
            .process_key
            .clone()
    }

    pub(super) fn process(&self) -> Arc<ActiveAcpProcess> {
        Arc::clone(&self.process)
    }

    pub(super) fn attach_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
    ) -> Result<String, String> {
        self.process
            .attach_protocol_session(acp_id, session_id, project_dir)
    }

    pub(super) fn set_protocol_disconnect_task(&self, task: JoinHandle<()>) {
        self.process.set_protocol_disconnect_task(task);
    }

    pub(super) fn set_watchdog_task(&self, task: JoinHandle<()>) {
        self.process.set_watchdog_task(task);
    }

    pub(super) fn session_id(&self) -> String {
        self.snapshot
            .lock()
            .expect("ACP snapshot lock")
            .session_id
            .clone()
    }

    pub(super) fn pending_permission_count(&self) -> usize {
        self.permissions.pending_permission_count()
    }

    pub(super) fn pending_permission_batches(&self) -> Vec<AcpPermissionBatch> {
        self.permissions.pending_batches()
    }

    pub(super) fn resolve_permission_batch(
        &self,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> bool {
        self.permissions.resolve_batch(batch_id, decision).is_some()
    }

    pub(super) fn snapshot_with_live_counts(&self) -> AcpAgentSnapshot {
        let mut snapshot = self.snapshot.lock().expect("ACP snapshot lock").clone();
        snapshot.pending_permissions = self.permissions.pending_permission_count();
        snapshot.permission_queue_depth = self.permissions.queue_depth();
        snapshot.pending_permission_batches = self.permissions.pending_batches();
        snapshot
    }

    pub(super) fn inspect_snapshot(&self) -> AcpAgentInspectSnapshot {
        let snapshot = self.snapshot_with_live_counts();
        let prompt_timeout = self.process.supervisor.config().prompt_timeout;
        let elapsed_since_last_event = self.process.supervisor.elapsed_since_last_event();
        let remaining = prompt_timeout
            .checked_sub(elapsed_since_last_event)
            .unwrap_or_default();
        AcpAgentInspectSnapshot {
            acp_id: snapshot.acp_id,
            session_id: snapshot.session_id,
            agent_id: snapshot.agent_id,
            display_name: snapshot.display_name,
            pid: snapshot.pid,
            pgid: snapshot.pgid,
            process_key: snapshot.process_key,
            uptime_ms: u64::try_from(self.process.started_at.elapsed().as_millis())
                .unwrap_or(u64::MAX),
            last_update_at: snapshot.updated_at,
            last_client_call_at: self.process.supervisor.last_client_call_at(),
            watchdog_state: self
                .process
                .supervisor
                .watchdog_state()
                .as_str()
                .to_string(),
            permission_mode: snapshot.permission_mode,
            permission_log_path: snapshot.permission_log_path,
            pending_permissions: snapshot.pending_permissions,
            permission_queue_depth: snapshot.permission_queue_depth,
            terminal_count: snapshot.terminal_count,
            prompt_deadline_remaining_ms: u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        }
    }

    pub(super) fn refresh(&self) {
        if self
            .snapshot
            .lock()
            .expect("ACP snapshot lock")
            .status
            .is_disconnected()
        {
            return;
        }
        if let Some(reason) = self.process.refresh_disconnect_reason() {
            self.disconnect(reason, false);
        }
    }

    pub(super) fn disconnect_for_stop(&self) -> Result<usize, String> {
        self.disconnect_inner(DisconnectReason::SessionStopped, false, true)
    }

    pub(super) fn disconnect(&self, reason: DisconnectReason, terminate_process: bool) -> usize {
        self.disconnect_inner(reason, terminate_process, false)
            .unwrap_or_else(|error| self.continue_after_detach_failure(&error))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn continue_after_detach_failure(&self, error: &str) -> usize {
        tracing::warn!(%error, "continuing ACP disconnect after detach failure");
        self.permissions.shutdown_pending()
    }

    fn disconnect_inner(
        &self,
        reason: DisconnectReason,
        terminate_process: bool,
        fail_on_detach: bool,
    ) -> Result<usize, String> {
        let (acp_id, mut snapshot) =
            self.detach_protocol_route_if_needed(&reason, terminate_process, fail_on_detach)?;
        if terminate_process {
            self.process.request_cancel();
            self.process.abort_non_protocol_tasks();
            self.process.supervisor.mark_done();
        }
        let pending_permissions = self.permissions.shutdown_pending();
        if snapshot.status.is_disconnected() {
            return Ok(pending_permissions);
        }
        snapshot.status = AgentStatus::Disconnected {
            reason,
            stderr_tail: self.process.stderr_tail.as_string(),
        };
        snapshot.updated_at = utc_now();
        drop(snapshot);
        self.process.remove_logical_session(&acp_id);
        Ok(pending_permissions)
    }

    fn detach_protocol_route_if_needed(
        &self,
        reason: &DisconnectReason,
        terminate_process: bool,
        fail_on_detach: bool,
    ) -> Result<(String, MutexGuard<'_, AcpAgentSnapshot>), String> {
        let mut snapshot = self.snapshot.lock().expect("ACP snapshot lock");
        let (acp_id, session_id) = snapshot_route(&snapshot);
        if should_detach_protocol_route(&snapshot, reason, terminate_process) {
            drop(snapshot);
            self.detach_protocol_route(&acp_id, &session_id, fail_on_detach)?;
            snapshot = self.snapshot.lock().expect("ACP snapshot lock");
        }
        Ok((acp_id, snapshot))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn detach_protocol_route(
        &self,
        acp_id: &str,
        session_id: &str,
        fail_on_detach: bool,
    ) -> Result<(), String> {
        if let Err(error) = self.process.detach_protocol_session(acp_id, session_id) {
            if fail_on_detach {
                return Err(error);
            }
            tracing::warn!(%error, acp_id, session_id, "failed to detach ACP protocol session");
        }
        Ok(())
    }

    pub(super) fn terminate_process(&self, pending_permissions: usize) {
        self.process.request_cancel();
        self.process.abort_non_protocol_tasks();
        self.process.supervisor.mark_done();
        self.process.kill_child(pending_permissions);
    }
}

fn snapshot_route(snapshot: &AcpAgentSnapshot) -> (String, String) {
    (snapshot.acp_id.clone(), snapshot.session_id.clone())
}

fn should_detach_protocol_route(
    snapshot: &AcpAgentSnapshot,
    reason: &DisconnectReason,
    terminate_process: bool,
) -> bool {
    matches!(reason, DisconnectReason::SessionStopped)
        && !terminate_process
        && !snapshot.status.is_disconnected()
}

impl Drop for ActiveAcpSession {
    fn drop(&mut self) {
        let snapshot = self.snapshot.lock().expect("ACP snapshot lock");
        let acp_id = snapshot.acp_id.clone();
        let should_terminate = !snapshot.status.is_disconnected();
        drop(snapshot);
        let pending_permissions = self.permissions.shutdown_pending();
        self.process.remove_logical_session(&acp_id);
        if should_terminate && self.process.logical_session_count() == 0 {
            self.process.request_cancel();
            self.process.abort_tasks();
            self.process.kill_child(pending_permissions);
        }
    }
}

impl SharedStderrTail {
    pub(super) fn spawn(stderr: Option<ChildStderr>) -> Self {
        let tail = Self::default();
        if let Some(mut stderr) = stderr {
            let writer = tail.clone();
            thread::spawn(move || {
                let mut buffer = [0_u8; 4096];
                while let Ok(n) = stderr.read(&mut buffer) {
                    if n == 0 {
                        break;
                    }
                    writer.append(&buffer[..n]);
                }
            });
        }
        tail
    }

    fn append(&self, bytes: &[u8]) {
        let mut tail = self.bytes.lock().expect("stderr tail lock");
        tail.extend_from_slice(bytes);
        if tail.len() > STDERR_TAIL_LIMIT {
            let excess = tail.len() - STDERR_TAIL_LIMIT;
            tail.drain(..excess);
        }
    }

    fn as_string(&self) -> Option<String> {
        let tail = self.bytes.lock().expect("stderr tail lock");
        if tail.is_empty() {
            None
        } else {
            Some(String::from_utf8_lossy(&tail).into_owned())
        }
    }
}

pub(super) fn spawn_event_forwarder(
    sender: broadcast::Sender<StreamEvent>,
    mut events: mpsc::Receiver<EventBatch>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(batch) = events.recv().await {
            let payload = serde_json::json!({
                "acp_id": batch.acp_id,
                "session_id": batch.session_id,
                "raw_count": batch.raw_count,
                "events": batch.events,
            });
            let _ = sender.send(StreamEvent {
                event: "acp_events".to_string(),
                recorded_at: utc_now(),
                session_id: Some(batch.session_id),
                payload,
            });
        }
    })
}

pub(super) fn spawn_protocol_disconnect_forwarder(
    manager: AcpAgentManagerHandle,
    active: Weak<ActiveAcpSession>,
    mut disconnects: mpsc::Receiver<DisconnectReason>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let Some(reason) = disconnects.recv().await else {
            return;
        };
        manager.disconnect_forwarded_session(&active, reason);
    })
}

pub(super) fn spawn_watchdog_forwarder(
    manager: AcpAgentManagerHandle,
    active: Weak<ActiveAcpSession>,
    supervisor: Arc<AcpSessionSupervisor>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let Some(reason) = watchdog_loop(supervisor).await else {
            return;
        };
        manager.disconnect_forwarded_session(&active, reason);
    })
}

fn process_incident_event(snapshot: &AcpAgentSnapshot) -> Option<StreamEvent> {
    let AgentStatus::Disconnected {
        reason,
        stderr_tail,
    } = &snapshot.status
    else {
        return None;
    };
    let kind = match reason {
        DisconnectReason::ProcessExited { .. } => "process_exit",
        DisconnectReason::TransportClosed => "transport_closed",
        DisconnectReason::StdioClosed => "stdio_closed",
        DisconnectReason::InitializeTimeout | DisconnectReason::PromptTimeout => "protocol_desync",
        DisconnectReason::WatchdogFired => "watchdog_fired",
        DisconnectReason::SessionStopped
        | DisconnectReason::UserCancelled
        | DisconnectReason::DaemonShutdown
        | DisconnectReason::OomKilled
        | DisconnectReason::Unknown { .. } => return None,
    };
    let (exit_code, exit_signal) = match reason {
        DisconnectReason::ProcessExited { code, signal } => (*code, *signal),
        _ => (None, None),
    };
    let payload = AcpProcessIncidentPayload {
        kind: kind.to_string(),
        reason_kind: reason_kind(reason),
        process_key: snapshot.process_key.clone(),
        pid: snapshot.pid,
        pgid: snapshot.pgid,
        exit_code,
        exit_signal,
        restart_applied: false,
        backoff_applied: false,
        quarantine_applied: false,
        stderr_tail: stderr_tail.clone(),
        affected_logical_session_ids: sorted_singleton(snapshot.session_id.clone()),
    };
    Some(StreamEvent {
        event: "acp_process_incident".to_string(),
        recorded_at: utc_now(),
        session_id: Some(snapshot.session_id.clone()),
        payload: serde_json::to_value(payload).ok()?,
    })
}

pub(super) fn process_incident_from_snapshot(snapshot: &AcpAgentSnapshot) -> Option<StreamEvent> {
    process_incident_event(snapshot)
}

fn sorted_singleton(session_id: String) -> Vec<String> {
    let mut ids = vec![session_id];
    ids.sort();
    ids
}

fn reason_kind(reason: &DisconnectReason) -> String {
    match reason {
        DisconnectReason::ProcessExited { .. } => "process_exited".to_string(),
        DisconnectReason::StdioClosed => "stdio_closed".to_string(),
        DisconnectReason::TransportClosed => "transport_closed".to_string(),
        DisconnectReason::InitializeTimeout => "initialize_timeout".to_string(),
        DisconnectReason::PromptTimeout => "prompt_timeout".to_string(),
        DisconnectReason::WatchdogFired => "watchdog_fired".to_string(),
        DisconnectReason::UserCancelled => "user_cancelled".to_string(),
        DisconnectReason::SessionStopped => "session_stopped".to_string(),
        DisconnectReason::DaemonShutdown => "daemon_shutdown".to_string(),
        DisconnectReason::OomKilled => "oom_killed".to_string(),
        DisconnectReason::Unknown { raw_kind } => {
            if let Some(value) = raw_kind {
                return value.clone();
            }
            "unknown".to_string()
        }
    }
}

#[cfg(test)]
mod tests;
