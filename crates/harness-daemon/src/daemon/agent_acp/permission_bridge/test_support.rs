use agent_client_protocol::schema::v1::{
    RequestPermissionRequest, ToolCallUpdate, ToolCallUpdateFields,
};
use tokio::sync::broadcast;
use tokio::sync::oneshot;

use super::*;
use crate::agents::acp::permission::standard_permission_options;
use crate::daemon::test_liveness::LIVENESS;

pub(super) fn permission_request(
    id: &str,
) -> (
    PermissionBridgeRequest,
    oneshot::Receiver<PermissionBridgeResult>,
) {
    permission_request_for_session(id, "acp-session")
}

pub(super) fn permission_request_for_session(
    id: &str,
    acp_session_id: &str,
) -> (
    PermissionBridgeRequest,
    oneshot::Receiver<PermissionBridgeResult>,
) {
    let (tx, rx) = oneshot::channel();
    let tool_call = ToolCallUpdate::new(id.to_string(), ToolCallUpdateFields::new());
    let request = RequestPermissionRequest::new(
        acp_session_id.to_string(),
        tool_call,
        standard_permission_options(),
    );
    (
        PermissionBridgeRequest {
            request,
            deadline: Duration::from_secs(30),
            response_tx: tx,
        },
        rx,
    )
}

#[track_caller]
pub(super) fn unwrap_ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
    assert!(
        result.is_ok(),
        "{context}: unexpected Err({:?})",
        result.as_ref().err()
    );
    let Ok(value) = result else {
        unreachable!("{context}");
    };
    value
}

#[track_caller]
pub(super) fn unwrap_some<T>(value: Option<T>, context: &str) -> T {
    assert!(value.is_some(), "{context}: unexpected None");
    let Some(value) = value else {
        unreachable!("{context}");
    };
    value
}

#[track_caller]
pub(super) fn unwrap_err<T: std::fmt::Debug, E: std::fmt::Debug>(
    result: Result<T, E>,
    context: &str,
) -> E {
    assert!(
        result.is_err(),
        "{context}: unexpected Ok({:?})",
        result.as_ref().ok()
    );
    let Err(error) = result else {
        unreachable!("{context}");
    };
    error
}

pub(super) async fn recv_permission_result(
    rx: oneshot::Receiver<PermissionBridgeResult>,
) -> PermissionBridgeResult {
    let result = unwrap_ok(
        tokio::time::timeout(LIVENESS, rx).await,
        "permission response should arrive",
    );
    unwrap_ok(result, "permission response channel should stay open")
}

/// Polls until `probe` yields a value, then returns it.
pub(super) async fn settles<T>(label: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = std::time::Instant::now() + LIVENESS;
    loop {
        if let Some(value) = probe() {
            return value;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{label} never settled"
        );
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

/// Waits for the bridge to absorb `requests` sends into a single batch.
pub(super) async fn coalesced_batch(
    bridge: &PermissionBridgeHandle,
    requests: usize,
) -> Vec<AcpPermissionBatch> {
    settles(&format!("one batch holding {requests} requests"), || {
        let batches = bridge.pending_batches();
        (batches.len() == 1 && batches[0].requests.len() == requests).then_some(batches)
    })
    .await
}

/// Waits for the bridge to hold `pending` permissions.
pub(super) async fn pending_permissions(bridge: &PermissionBridgeHandle, pending: usize) {
    settles(&format!("{pending} pending permissions"), || {
        (bridge.pending_permission_count() == pending).then_some(())
    })
    .await;
}

/// Waits for the bridge to hold `tasks` expiration handles.
pub(super) async fn expiration_tasks(bridge: &PermissionBridgeHandle, tasks: usize) {
    settles(&format!("{tasks} expiration tasks"), || {
        (bridge.expiration_task_count() == tasks).then_some(())
    })
    .await;
}

/// Reads the next broadcast event, so a test never depends on the event already
/// sitting in the channel at the moment it looks.
pub(super) async fn next_broadcast(receiver: &mut broadcast::Receiver<StreamEvent>) -> StreamEvent {
    let received = unwrap_ok(
        tokio::time::timeout(LIVENESS, receiver.recv()).await,
        "an event should be broadcast",
    );
    unwrap_ok(received, "broadcast channel should stay open")
}

/// Reads broadcast events until one matches `event`.
pub(super) async fn next_event(
    receiver: &mut broadcast::Receiver<StreamEvent>,
    event: &str,
) -> StreamEvent {
    loop {
        let received = next_broadcast(receiver).await;
        if received.event == event {
            return received;
        }
    }
}

pub(super) async fn permission_requested_sessions(
    receiver: &mut broadcast::Receiver<StreamEvent>,
    expected: usize,
) -> Vec<String> {
    let mut sessions = Vec::new();
    while sessions.len() < expected {
        let event = next_event(receiver, "acp_permission_requested").await;
        if let Some(session_id) = event.session_id {
            sessions.push(session_id);
        }
    }
    sessions.sort();
    sessions
}
