use std::io::Read;
use std::process::{Child, ChildStderr, ExitStatus};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;

use crate::agents::acp::connection::EventBatch;
use crate::agents::acp::supervision::{AcpSessionSupervisor, kill_process_group};
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::manager::{AcpAgentInspectSnapshot, AcpAgentSnapshot};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision, PermissionBridgeHandle};

const STDERR_TAIL_LIMIT: usize = 16 * 1024;
const PERMISSION_SHUTDOWN_FLUSH_GRACE: Duration = Duration::from_millis(25);

pub(super) struct ActiveAcpSession {
    snapshot: Mutex<AcpAgentSnapshot>,
    child: Mutex<Option<Child>>,
    supervisor: Arc<AcpSessionSupervisor>,
    permissions: PermissionBridgeHandle,
    stderr_tail: SharedStderrTail,
    protocol_task: Mutex<Option<JoinHandle<()>>>,
    batcher_task: Mutex<Option<JoinHandle<()>>>,
    event_task: Mutex<Option<JoinHandle<()>>>,
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

impl ActiveAcpSession {
    #[must_use]
    pub(super) fn new(
        snapshot: AcpAgentSnapshot,
        child: Child,
        supervisor: Arc<AcpSessionSupervisor>,
        permissions: PermissionBridgeHandle,
        stderr_tail: SharedStderrTail,
        tasks: ActiveAcpTasks,
    ) -> Self {
        Self {
            snapshot: Mutex::new(snapshot),
            child: Mutex::new(Some(child)),
            supervisor,
            permissions,
            stderr_tail,
            protocol_task: Mutex::new(Some(tasks.protocol)),
            batcher_task: Mutex::new(Some(tasks.batcher)),
            event_task: Mutex::new(Some(tasks.event)),
            started_at: Instant::now(),
        }
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
            uptime_ms: u64::try_from(self.started_at.elapsed().as_millis()).unwrap_or(u64::MAX),
            last_update_at: snapshot.updated_at,
            last_client_call_at: self.supervisor.last_client_call_at(),
            watchdog_state: self.supervisor.watchdog_state().as_str().to_string(),
            pending_permissions: snapshot.pending_permissions,
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
}

impl Drop for ActiveAcpSession {
    fn drop(&mut self) {
        let pending_permissions = self.permissions.shutdown_pending();
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
