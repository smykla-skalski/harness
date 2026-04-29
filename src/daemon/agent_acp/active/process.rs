use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::{Child, ExitStatus};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use tokio::task::JoinHandle;

use crate::agents::acp::supervision::{AcpSessionSupervisor, kill_process_group};
use crate::agents::kind::DisconnectReason;

use super::SharedStderrTail;
use crate::daemon::agent_acp::prompt_gate::{PromptGate, PromptOwner};
use crate::daemon::agent_acp::protocol::AcpProtocolHandle;

const PROTOCOL_CANCEL_FLUSH_GRACE: Duration = Duration::from_millis(25);
const PERMISSION_SHUTDOWN_FLUSH_GRACE: Duration = Duration::from_millis(25);

pub(in crate::daemon::agent_acp) struct ActiveAcpProcess {
    child: Mutex<Option<Child>>,
    pub(super) supervisor: Arc<AcpSessionSupervisor>,
    protocol_handle: AcpProtocolHandle,
    pub(super) stderr_tail: SharedStderrTail,
    protocol_task: Mutex<Option<JoinHandle<()>>>,
    batcher_task: Mutex<Option<JoinHandle<()>>>,
    event_task: Mutex<Option<JoinHandle<()>>>,
    protocol_disconnect_task: Mutex<Option<JoinHandle<()>>>,
    watchdog_task: Mutex<Option<JoinHandle<()>>>,
    prompt_gate: PromptGate,
    pub(super) started_at: Instant,
    disconnect_reason: Mutex<Option<DisconnectReason>>,
    logical_acp_ids: Mutex<BTreeSet<String>>,
}

pub(in crate::daemon::agent_acp) struct ActiveAcpTasks {
    pub protocol: JoinHandle<()>,
    pub batcher: JoinHandle<()>,
    pub event: JoinHandle<()>,
}

impl ActiveAcpProcess {
    #[must_use]
    pub(in crate::daemon::agent_acp) fn new(
        child: Child,
        supervisor: Arc<AcpSessionSupervisor>,
        protocol_handle: AcpProtocolHandle,
        prompt_gate: PromptGate,
        stderr_tail: SharedStderrTail,
        tasks: ActiveAcpTasks,
    ) -> Self {
        Self {
            child: Mutex::new(Some(child)),
            supervisor,
            protocol_handle,
            stderr_tail,
            protocol_task: Mutex::new(Some(tasks.protocol)),
            batcher_task: Mutex::new(Some(tasks.batcher)),
            event_task: Mutex::new(Some(tasks.event)),
            protocol_disconnect_task: Mutex::new(None),
            watchdog_task: Mutex::new(None),
            prompt_gate,
            started_at: Instant::now(),
            disconnect_reason: Mutex::new(None),
            logical_acp_ids: Mutex::new(BTreeSet::new()),
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

    pub(super) fn add_logical_session(&self, acp_id: &str) {
        self.logical_acp_ids
            .lock()
            .expect("ACP process logical session lock")
            .insert(acp_id.to_string());
    }

    pub(super) fn remove_logical_session(&self, acp_id: &str) {
        self.logical_acp_ids
            .lock()
            .expect("ACP process logical session lock")
            .remove(acp_id);
    }

    pub(in crate::daemon::agent_acp) fn logical_session_count(&self) -> usize {
        self.logical_acp_ids
            .lock()
            .expect("ACP process logical session lock")
            .len()
    }

    pub(super) fn refresh_disconnect_reason(&self) -> Option<DisconnectReason> {
        if let Some(reason) = self
            .disconnect_reason
            .lock()
            .expect("ACP process disconnect lock")
            .clone()
        {
            return Some(reason);
        }
        let mut child_guard = self.child.lock().expect("ACP child lock");
        let Some(child) = child_guard.as_mut() else {
            return self
                .disconnect_reason
                .lock()
                .expect("ACP process disconnect lock")
                .clone();
        };
        let Ok(Some(status)) = child.try_wait() else {
            return None;
        };
        let reason = process_exit_reason(status);
        drop(child_guard.take());
        self.abort_non_protocol_tasks();
        self.supervisor.mark_done();
        *self
            .disconnect_reason
            .lock()
            .expect("ACP process disconnect lock") = Some(reason.clone());
        Some(reason)
    }

    pub(super) fn kill_child(&self, pending_permissions: usize) {
        let mut child = self.child.lock().expect("ACP child lock");
        if let Some(mut child) = child.take() {
            let pgid = self.supervisor.pgid();
            let handle = thread::spawn(move || {
                if pending_permissions > 0 {
                    thread::sleep(PERMISSION_SHUTDOWN_FLUSH_GRACE);
                }
                kill_process_group(pgid, &mut child);
            });
            let _ = handle.join();
        }
    }

    pub(super) fn abort_non_protocol_tasks(&self) {
        abort_task(&self.batcher_task, "ACP batcher task lock");
        abort_task(&self.event_task, "ACP event task lock");
        abort_task(
            &self.protocol_disconnect_task,
            "ACP protocol disconnect task lock",
        );
        abort_task(&self.watchdog_task, "ACP watchdog task lock");
    }

    pub(super) fn abort_tasks(&self) {
        abort_task(&self.protocol_task, "ACP protocol task lock");
        self.abort_non_protocol_tasks();
    }

    pub(super) fn request_cancel(&self) {
        self.protocol_handle.cancel();
        thread::sleep(PROTOCOL_CANCEL_FLUSH_GRACE);
    }

    pub(super) fn attach_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
    ) -> Result<String, String> {
        self.protocol_handle
            .attach_session(acp_id, session_id, project_dir)
            .map(|session_id| session_id.to_string())
    }

    pub(super) fn prompt_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
        prompt: String,
    ) -> Result<String, String> {
        let lease = self
            .prompt_gate
            .acquire(PromptOwner::new(acp_id, session_id))
            .map_err(|error| error.message())?;
        self.protocol_handle
            .prompt_session(acp_id, session_id, project_dir, prompt, lease)
            .map(|session_id| session_id.to_string())
    }

    pub(super) fn detach_protocol_session(
        &self,
        acp_id: &str,
        session_id: &str,
    ) -> Result<(), String> {
        self.protocol_handle.detach_session(acp_id, session_id)
    }
}

impl Drop for ActiveAcpProcess {
    fn drop(&mut self) {
        self.request_cancel();
        self.abort_tasks();
        self.kill_child(0);
    }
}

fn abort_task(task: &Mutex<Option<JoinHandle<()>>>, lock_name: &str) {
    if let Some(task) = task.lock().expect(lock_name).take() {
        task.abort();
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
