use std::collections::{BTreeMap, BTreeSet};
use std::mem;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::SyncSender;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::{
    PermissionOption, PermissionOptionKind, RequestPermissionOutcome, RequestPermissionResponse,
    SelectedPermissionOutcome,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::sync::{Notify, broadcast::Sender as BroadcastSender};
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::agents::acp::client::{DAEMON_SHUTDOWN, PERMISSION_CAP_REACHED};
use crate::agents::acp::permission::{
    PermissionBridgeError, PermissionBridgeRequest, PermissionBridgeResult, PermissionMode,
};
use crate::daemon::protocol::StreamEvent;
use crate::workspace::utc_now;

const COALESCE_WINDOW: Duration = Duration::from_millis(5);
pub(crate) const DEFAULT_PERMISSION_CAP: usize = 8;
const BRIDGE_CHANNEL_BUFFER: usize = 64;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AcpPermissionItem {
    pub request_id: String,
    pub session_id: String,
    pub tool_call: Value,
    pub options: Vec<PermissionOption>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AcpPermissionBatch {
    pub batch_id: String,
    pub acp_id: String,
    pub session_id: String,
    pub requests: Vec<AcpPermissionItem>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum AcpPermissionDecision {
    ApproveAll,
    ApproveSome { request_ids: BTreeSet<String> },
    DenyAll,
}

#[derive(Clone)]
pub struct PermissionBridgeHandle {
    tx: mpsc::Sender<PermissionBridgeRequest>,
    state: Arc<PermissionBridgeState>,
    worker: Arc<Mutex<Option<JoinHandle<()>>>>,
}

struct PermissionBridgeState {
    acp_id: String,
    session_id: String,
    sender: BroadcastSender<StreamEvent>,
    pending: Mutex<BTreeMap<String, PendingBatch>>,
    next_batch: AtomicU64,
    cap: usize,
    shutdown: AtomicBool,
    shutdown_notify: Notify,
}

struct PendingBatch {
    sequence: u64,
    batch: AcpPermissionBatch,
    responders: Vec<PendingResponder>,
}

struct PendingResponder {
    request_id: String,
    options: Vec<PermissionOption>,
    response_tx: SyncSender<PermissionBridgeResult>,
}

impl PermissionBridgeHandle {
    #[must_use]
    pub fn spawn(acp_id: String, session_id: String, sender: BroadcastSender<StreamEvent>) -> Self {
        let (tx, rx) = mpsc::channel(BRIDGE_CHANNEL_BUFFER);
        let state = Arc::new(PermissionBridgeState {
            acp_id,
            session_id,
            sender,
            pending: Mutex::new(BTreeMap::new()),
            next_batch: AtomicU64::new(1),
            cap: DEFAULT_PERMISSION_CAP,
            shutdown: AtomicBool::new(false),
            shutdown_notify: Notify::new(),
        });
        let worker_state = Arc::clone(&state);
        let worker = tokio::spawn(async move {
            permission_worker(rx, worker_state).await;
        });
        Self {
            tx,
            state,
            worker: Arc::new(Mutex::new(Some(worker))),
        }
    }

    #[must_use]
    pub fn mode(&self, deadline: Duration) -> PermissionMode {
        PermissionMode::DaemonBridge {
            tx: self.tx.clone(),
            deadline,
        }
    }

    #[must_use]
    pub fn pending_permission_count(&self) -> usize {
        self.state.pending_permission_count()
    }

    #[must_use]
    pub fn queue_depth(&self) -> usize {
        self.tx.max_capacity().saturating_sub(self.tx.capacity())
    }

    /// Return unresolved permission batches for daemon inspection.
    ///
    /// # Panics
    ///
    /// Panics if the internal pending-permission mutex is poisoned.
    #[must_use]
    pub fn pending_batches(&self) -> Vec<AcpPermissionBatch> {
        let mut batches: Vec<_> = self
            .state
            .pending
            .lock()
            .expect("permission bridge pending lock")
            .values()
            .map(|pending| (pending.sequence, pending.batch.clone()))
            .collect();
        batches.sort_by_key(|(sequence, _)| *sequence);
        batches.into_iter().map(|(_, batch)| batch).collect()
    }

    /// Fail every pending permission request with daemon shutdown.
    ///
    /// # Panics
    ///
    /// Panics if the internal pending-permission mutex or worker mutex is poisoned.
    pub fn shutdown_pending(&self) -> usize {
        if self.state.shutdown.swap(true, Ordering::SeqCst) {
            return 0;
        }
        let pending = mem::take(
            &mut *self
                .state
                .pending
                .lock()
                .expect("permission bridge pending lock"),
        );
        let pending_count: usize = pending
            .values()
            .map(|pending| pending.responders.len())
            .sum();
        for batch in pending.into_values() {
            for responder in batch.responders {
                let _ = responder.response_tx.send(Err(daemon_shutdown_error()));
            }
            self.state
                .broadcast("acp_permission_shutdown", &batch.batch);
        }
        let worker_alive = self
            .worker
            .lock()
            .expect("permission bridge worker lock")
            .take()
            .is_some();
        self.state.shutdown_notify.notify_waiters();
        pending_count.max(usize::from(worker_alive))
    }

    /// Resolve a pending permission batch.
    ///
    /// # Panics
    ///
    /// Panics if the internal pending-permission mutex is poisoned.
    #[must_use]
    pub fn resolve_batch(
        &self,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Option<AcpPermissionBatch> {
        let pending = self
            .state
            .pending
            .lock()
            .expect("permission bridge pending lock")
            .remove(batch_id)?;
        for responder in &pending.responders {
            let allow = decision.allows(&responder.request_id);
            let response = response_for_options(&responder.options, allow);
            let _ = responder.response_tx.send(Ok(response));
        }
        self.state
            .broadcast("acp_permission_resolved", &pending.batch);
        Some(pending.batch)
    }
}

impl AcpPermissionDecision {
    fn allows(&self, request_id: &str) -> bool {
        match self {
            Self::ApproveAll => true,
            Self::ApproveSome { request_ids } => request_ids.contains(request_id),
            Self::DenyAll => false,
        }
    }
}

impl PermissionBridgeState {
    fn pending_permission_count(&self) -> usize {
        self.pending
            .lock()
            .expect("permission bridge pending lock")
            .values()
            .map(|pending| pending.responders.len())
            .sum()
    }

    fn pending_responder_count_locked(pending: &BTreeMap<String, PendingBatch>) -> usize {
        pending
            .values()
            .map(|pending| pending.responders.len())
            .sum()
    }

    fn next_batch_id(&self) -> (String, u64) {
        let sequence = self.next_batch.fetch_add(1, Ordering::SeqCst);
        (
            format!("acp-permission-{}-{sequence}", self.acp_id),
            sequence,
        )
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn broadcast(&self, event: &str, payload: &impl Serialize) {
        let Some(stream_event) = self.stream_event(event, payload) else {
            tracing::warn!(event, "failed to serialize ACP permission event");
            return;
        };
        let _ = self.sender.send(stream_event);
    }

    fn stream_event(&self, event: &str, payload: &impl Serialize) -> Option<StreamEvent> {
        let payload = serde_json::to_value(payload).ok()?;
        Some(StreamEvent {
            event: event.to_string(),
            recorded_at: utc_now(),
            session_id: Some(self.session_id.clone()),
            payload,
        })
    }
}

async fn permission_worker(
    mut rx: mpsc::Receiver<PermissionBridgeRequest>,
    state: Arc<PermissionBridgeState>,
) {
    loop {
        tokio::select! {
            request = rx.recv() => {
                let Some(first) = request else {
                    return;
                };
                if state.shutdown.load(Ordering::SeqCst) {
                    reject_requests(vec![first], &daemon_shutdown_error());
                    reject_queued_requests(&mut rx);
                    return;
                }
                if !process_permission_request(&mut rx, &state, first).await {
                    return;
                }
            }
            () = state.shutdown_notify.notified() => {
                reject_queued_requests(&mut rx);
                return;
            }
        }
    }
}

async fn process_permission_request(
    rx: &mut mpsc::Receiver<PermissionBridgeRequest>,
    state: &Arc<PermissionBridgeState>,
    first: PermissionBridgeRequest,
) -> bool {
    let mut requests = vec![first];
    tokio::select! {
        () = sleep(COALESCE_WINDOW) => {
            drain_concurrent_requests(rx, &mut requests);
            enqueue_or_reject_batch(state, requests);
            true
        }
        () = state.shutdown_notify.notified() => {
            reject_requests(requests, &daemon_shutdown_error());
            reject_queued_requests(rx);
            false
        }
    }
}

fn drain_concurrent_requests(
    rx: &mut mpsc::Receiver<PermissionBridgeRequest>,
    requests: &mut Vec<PermissionBridgeRequest>,
) {
    while let Ok(request) = rx.try_recv() {
        requests.push(request);
    }
}

fn enqueue_or_reject_batch(
    state: &Arc<PermissionBridgeState>,
    requests: Vec<PermissionBridgeRequest>,
) {
    let mut accepted = Vec::new();
    let mut pending = state
        .pending
        .lock()
        .expect("permission bridge pending lock");
    let pending_count = PermissionBridgeState::pending_responder_count_locked(&pending);
    for request in requests {
        if state.shutdown.load(Ordering::SeqCst) {
            reject_request(&request.response_tx, daemon_shutdown_error());
        } else if pending_count + accepted.len() >= state.cap {
            reject_request(&request.response_tx, permission_cap_error(state.cap));
        } else {
            accepted.push(request);
        }
    }
    if accepted.is_empty() {
        return;
    }
    let batch = enqueue_batch_locked(state, &mut pending, accepted);
    drop(pending);
    state.broadcast("acp_permission_requested", &batch);
}

fn enqueue_batch_locked(
    state: &PermissionBridgeState,
    pending: &mut BTreeMap<String, PendingBatch>,
    requests: Vec<PermissionBridgeRequest>,
) -> AcpPermissionBatch {
    let (batch_id, sequence) = state.next_batch_id();
    let created_at = utc_now();
    let mut items = Vec::with_capacity(requests.len());
    let mut responders = Vec::with_capacity(requests.len());

    for (index, request) in requests.into_iter().enumerate() {
        let request_id = format!("{batch_id}:{index}");
        let tool_call = serde_json::to_value(&request.request.tool_call).unwrap_or(Value::Null);
        items.push(AcpPermissionItem {
            request_id: request_id.clone(),
            session_id: request.request.session_id.to_string(),
            tool_call,
            options: request.request.options.clone(),
        });
        responders.push(PendingResponder {
            request_id,
            options: request.request.options,
            response_tx: request.response_tx,
        });
    }

    let batch = AcpPermissionBatch {
        batch_id: batch_id.clone(),
        acp_id: state.acp_id.clone(),
        session_id: state.session_id.clone(),
        requests: items,
        created_at,
    };
    pending.insert(
        batch_id,
        PendingBatch {
            sequence,
            batch: batch.clone(),
            responders,
        },
    );
    batch
}

fn reject_request(response_tx: &SyncSender<PermissionBridgeResult>, error: PermissionBridgeError) {
    let _ = response_tx.send(Err(error));
}

fn reject_requests(requests: Vec<PermissionBridgeRequest>, error: &PermissionBridgeError) {
    for request in requests {
        reject_request(&request.response_tx, error.clone());
    }
}

fn reject_queued_requests(rx: &mut mpsc::Receiver<PermissionBridgeRequest>) {
    while let Ok(request) = rx.try_recv() {
        reject_request(&request.response_tx, daemon_shutdown_error());
    }
}

fn daemon_shutdown_error() -> PermissionBridgeError {
    PermissionBridgeError::new(DAEMON_SHUTDOWN, "daemon shutdown in progress")
}

fn permission_cap_error(cap: usize) -> PermissionBridgeError {
    PermissionBridgeError::new(
        PERMISSION_CAP_REACHED,
        format!("permission concurrency cap reached ({cap})"),
    )
}

fn response_for_options(options: &[PermissionOption], allow: bool) -> RequestPermissionResponse {
    let option = options.iter().find(|option| {
        matches!(
            (allow, option.kind),
            (
                true,
                PermissionOptionKind::AllowOnce | PermissionOptionKind::AllowAlways
            ) | (
                false,
                PermissionOptionKind::RejectOnce | PermissionOptionKind::RejectAlways
            )
        )
    });
    option.map_or_else(
        || RequestPermissionResponse::new(RequestPermissionOutcome::Cancelled),
        |option| {
            RequestPermissionResponse::new(RequestPermissionOutcome::Selected(
                SelectedPermissionOutcome::new(option.option_id.clone()),
            ))
        },
    )
}

#[cfg(test)]
mod tests;
