use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use serde::Serialize;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;

use crate::agents::acp::connection::EventBatch;
use crate::agents::acp::supervision::{AcpSessionSupervisor, watchdog_loop};
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::manager::{AcpAgentManagerHandle, AcpAgentSnapshot};

const STDERR_TAIL_LIMIT: usize = 16 * 1024;
const STDERR_READER_JOIN_GRACE: Duration = Duration::from_millis(100);
const STDERR_READER_JOIN_POLL: Duration = Duration::from_millis(5);

mod process;
mod session;
mod stderr_tail;

pub(in crate::daemon::agent_acp) use process::{ActiveAcpProcess, ActiveAcpTasks};
pub(in crate::daemon::agent_acp) use session::ActiveAcpSession;
pub(in crate::daemon::agent_acp) use stderr_tail::SharedStderrTail;

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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn recover_lock<'a, T>(mutex: &'a Mutex<T>, label: &str) -> MutexGuard<'a, T> {
    mutex
        .lock()
        .unwrap_or_else(|error: PoisonError<MutexGuard<'a, T>>| {
            tracing::warn!(%error, lock = label, "recovering poisoned ACP lock");
            error.into_inner()
        })
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
        if let Err(error) = manager.disconnect_forwarded_session(&active, reason) {
            tracing::warn!(%error, "failed to disconnect forwarded ACP session");
        }
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
        if let Err(error) = manager.disconnect_forwarded_session(&active, reason) {
            tracing::warn!(%error, "failed to disconnect watchdog-fired ACP session");
        }
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
        DisconnectReason::TransportClosed | DisconnectReason::StdioClosed => "transport_closed",
        DisconnectReason::InitializeTimeout | DisconnectReason::PromptTimeout => "protocol_desync",
        DisconnectReason::WatchdogFired => "watchdog_fired",
        DisconnectReason::SessionStopped
        | DisconnectReason::SessionEnded
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
        DisconnectReason::SessionEnded => "session_ended".to_string(),
        DisconnectReason::DaemonShutdown => "daemon_shutdown".to_string(),
        DisconnectReason::OomKilled => "oom_killed".to_string(),
        DisconnectReason::Unknown { raw_kind } => {
            raw_kind.clone().unwrap_or_else(|| "unknown".to_string())
        }
    }
}

#[cfg(test)]
mod tests;
