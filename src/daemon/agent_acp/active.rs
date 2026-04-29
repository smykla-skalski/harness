use std::io::Read;
use std::process::{Child, ChildStderr, ExitStatus};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;

use crate::agents::acp::connection::EventBatch;
use crate::agents::acp::supervision::{AcpSessionSupervisor, kill_process_group, watchdog_loop};
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::manager::{AcpAgentInspectSnapshot, AcpAgentSnapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision, PermissionBridgeHandle};
use super::protocol::AcpCancelHandle;

const STDERR_TAIL_LIMIT: usize = 16 * 1024;
const PROTOCOL_CANCEL_FLUSH_GRACE: Duration = Duration::from_millis(25);
const PERMISSION_SHUTDOWN_FLUSH_GRACE: Duration = Duration::from_millis(25);

pub(super) struct ActiveAcpSession {
    snapshot: Mutex<AcpAgentSnapshot>,
    child: Mutex<Option<Child>>,
    supervisor: Arc<AcpSessionSupervisor>,
    permissions: PermissionBridgeHandle,
    cancel: AcpCancelHandle,
    stderr_tail: SharedStderrTail,
    protocol_task: Mutex<Option<JoinHandle<()>>>,
    batcher_task: Mutex<Option<JoinHandle<()>>>,
    event_task: Mutex<Option<JoinHandle<()>>>,
    protocol_disconnect_task: Mutex<Option<JoinHandle<()>>>,
    watchdog_task: Mutex<Option<JoinHandle<()>>>,
    started_at: Instant,
}

pub(super) struct ActiveAcpTasks {
    pub protocol: JoinHandle<()>,
    pub batcher: JoinHandle<()>,
    pub event: JoinHandle<()>,
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
    stderr_tail: Option<String>,
    affected_logical_session_ids: Vec<String>,
}

impl ActiveAcpSession {
    #[must_use]
    pub(super) fn new(
        snapshot: AcpAgentSnapshot,
        child: Child,
        supervisor: Arc<AcpSessionSupervisor>,
        permissions: PermissionBridgeHandle,
        cancel: AcpCancelHandle,
        stderr_tail: SharedStderrTail,
        tasks: ActiveAcpTasks,
    ) -> Self {
        Self {
            snapshot: Mutex::new(snapshot),
            child: Mutex::new(Some(child)),
            supervisor,
            permissions,
            cancel,
            stderr_tail,
            protocol_task: Mutex::new(Some(tasks.protocol)),
            batcher_task: Mutex::new(Some(tasks.batcher)),
            event_task: Mutex::new(Some(tasks.event)),
            protocol_disconnect_task: Mutex::new(None),
            watchdog_task: Mutex::new(None),
            started_at: Instant::now(),
        }
    }

    pub(super) fn set_protocol_disconnect_task(&self, task: JoinHandle<()>) {
        *self
            .protocol_disconnect_task
            .lock()
            .expect("ACP protocol disconnect task lock") = Some(task);
    }

    pub(super) fn set_watchdog_task(&self, task: JoinHandle<()>) {
        *self.watchdog_task.lock().expect("ACP watchdog task lock") = Some(task);
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
        let prompt_timeout = self.supervisor.config().prompt_timeout;
        let elapsed_since_last_event = self.supervisor.elapsed_since_last_event();
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
            uptime_ms: u64::try_from(self.started_at.elapsed().as_millis()).unwrap_or(u64::MAX),
            last_update_at: snapshot.updated_at,
            last_client_call_at: self.supervisor.last_client_call_at(),
            watchdog_state: self.supervisor.watchdog_state().as_str().to_string(),
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

        let mut child_guard = self.child.lock().expect("ACP child lock");
        let Some(child) = child_guard.as_mut() else {
            return;
        };
        let Ok(Some(status)) = child.try_wait() else {
            return;
        };

        let reason = process_exit_reason(status);
        drop(child_guard.take());
        drop(child_guard);
        let pending_permissions = self.disconnect(reason);
        self.kill_child(pending_permissions);
    }

    pub(super) fn disconnect(&self, reason: DisconnectReason) -> usize {
        self.request_cancel();
        let pending_permissions = self.permissions.shutdown_pending();
        self.abort_non_protocol_tasks();
        self.supervisor.mark_done();
        let mut snapshot = self.snapshot.lock().expect("ACP snapshot lock");
        if snapshot.status.is_disconnected() {
            return pending_permissions;
        }
        snapshot.status = AgentStatus::Disconnected {
            reason,
            stderr_tail: self.stderr_tail.as_string(),
        };
        snapshot.updated_at = utc_now();
        pending_permissions
    }

    pub(super) fn kill_child(&self, pending_permissions: usize) {
        let mut child = self.child.lock().expect("ACP child lock");
        if let Some(mut child) = child.take() {
            let pgid = self.supervisor.pgid();
            let _ = thread::spawn(move || {
                if pending_permissions > 0 {
                    thread::sleep(PERMISSION_SHUTDOWN_FLUSH_GRACE);
                }
                kill_process_group(pgid, &mut child);
            });
        }
    }

    fn abort_non_protocol_tasks(&self) {
        if let Some(task) = self
            .batcher_task
            .lock()
            .expect("ACP batcher task lock")
            .take()
        {
            task.abort();
        }
        if let Some(task) = self.event_task.lock().expect("ACP event task lock").take() {
            task.abort();
        }
        if let Some(task) = self
            .protocol_disconnect_task
            .lock()
            .expect("ACP protocol disconnect task lock")
            .take()
        {
            task.abort();
        }
        if let Some(task) = self
            .watchdog_task
            .lock()
            .expect("ACP watchdog task lock")
            .take()
        {
            task.abort();
        }
    }

    fn abort_tasks(&self) {
        if let Some(task) = self
            .protocol_task
            .lock()
            .expect("ACP protocol task lock")
            .take()
        {
            task.abort();
        }
        self.abort_non_protocol_tasks();
    }

    fn request_cancel(&self) {
        self.cancel.cancel();
        thread::sleep(PROTOCOL_CANCEL_FLUSH_GRACE);
    }
}

impl Drop for ActiveAcpSession {
    fn drop(&mut self) {
        let pending_permissions = self.permissions.shutdown_pending();
        self.request_cancel();
        self.abort_tasks();
        self.kill_child(pending_permissions);
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
    acp_id: String,
    session_id: String,
    mut events: mpsc::Receiver<EventBatch>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(batch) = events.recv().await {
            let payload = serde_json::json!({
                "acp_id": acp_id,
                "session_id": session_id,
                "raw_count": batch.raw_count,
                "events": batch.events,
            });
            let _ = sender.send(StreamEvent {
                event: "acp_events".to_string(),
                recorded_at: utc_now(),
                session_id: Some(session_id.clone()),
                payload,
            });
        }
    })
}

pub(super) fn spawn_protocol_disconnect_forwarder(
    sender: broadcast::Sender<StreamEvent>,
    active: Weak<ActiveAcpSession>,
    mut disconnects: mpsc::Receiver<DisconnectReason>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let Some(reason) = disconnects.recv().await else {
            return;
        };
        disconnect_active_session(&sender, &active, reason);
    })
}

pub(super) fn spawn_watchdog_forwarder(
    sender: broadcast::Sender<StreamEvent>,
    active: Weak<ActiveAcpSession>,
    supervisor: Arc<AcpSessionSupervisor>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let Some(reason) = watchdog_loop(supervisor).await else {
            return;
        };
        disconnect_active_session(&sender, &active, reason);
    })
}

fn disconnect_active_session(
    sender: &broadcast::Sender<StreamEvent>,
    active: &Weak<ActiveAcpSession>,
    reason: DisconnectReason,
) {
    let Some(session) = active.upgrade() else {
        return;
    };
    session.refresh();
    let pending_permissions = session.disconnect(reason);
    session.kill_child(pending_permissions);
    let snapshot = session.snapshot_with_live_counts();
    if let Some(incident) = process_incident_event(&snapshot) {
        let _ = sender.send(incident);
    }
    let payload = serde_json::to_value(&snapshot).unwrap_or_default();
    let _ = sender.send(StreamEvent {
        event: "acp_agent_disconnected".to_string(),
        recorded_at: utc_now(),
        session_id: Some(snapshot.session_id),
        payload,
    });
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

fn process_exit_reason(status: ExitStatus) -> DisconnectReason {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        DisconnectReason::ProcessExited {
            code: status.code(),
            signal: status.signal(),
        }
    }
    #[cfg(not(unix))]
    {
        DisconnectReason::ProcessExited {
            code: status.code(),
            signal: None,
        }
    }
}

#[cfg(test)]
mod tests;
