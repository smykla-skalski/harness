use agent_client_protocol::schema::{
    RequestPermissionRequest, ToolCallUpdate, ToolCallUpdateFields,
};
use tokio::sync::broadcast;
use tokio::sync::oneshot;

use super::*;
use crate::agents::acp::permission::standard_permission_options;

fn permission_request(
    id: &str,
) -> (
    PermissionBridgeRequest,
    oneshot::Receiver<PermissionBridgeResult>,
) {
    permission_request_for_session(id, "acp-session")
}

fn permission_request_for_session(
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
fn unwrap_ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
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
fn unwrap_some<T>(value: Option<T>, context: &str) -> T {
    assert!(value.is_some(), "{context}: unexpected None");
    let Some(value) = value else {
        unreachable!("{context}");
    };
    value
}

#[track_caller]
fn unwrap_err<T: std::fmt::Debug, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> E {
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

async fn recv_permission_result(
    rx: oneshot::Receiver<PermissionBridgeResult>,
) -> PermissionBridgeResult {
    let result = unwrap_ok(
        tokio::time::timeout(Duration::from_millis(100), rx).await,
        "permission response should arrive",
    );
    unwrap_ok(result, "permission response channel should stay open")
}

#[tokio::test]
async fn coalesces_concurrent_requests_into_one_batch() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (req_a, rx_a) = permission_request("tool-a");
    let (req_b, rx_b) = permission_request("tool-b");

    unwrap_ok(bridge.tx.send(req_a).await, "send a");
    unwrap_ok(bridge.tx.send(req_b).await, "send b");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let batches = bridge.pending_batches();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].requests.len(), 2);
    let _ = bridge.resolve_batch(&batches[0].batch_id, &AcpPermissionDecision::ApproveAll);
    assert_eq!(bridge.expiration_task_count(), 0);
    let _ = unwrap_ok(
        recv_permission_result(rx_a).await,
        "rx_a should be approved",
    );
    let _ = unwrap_ok(
        recv_permission_result(rx_b).await,
        "rx_b should be approved",
    );
}

#[tokio::test]
async fn separate_logical_sessions_never_coalesce_permission_batches() {
    let (sender, mut events) = broadcast::channel(8);
    let bridge_a = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender.clone(),
    );
    let bridge_b = PermissionBridgeHandle::spawn(
        "acp-2".into(),
        "00b4a39f-719e-5418-abe8-eb3ab6ea614d".into(),
        sender,
    );
    let (req_a, rx_a) = permission_request_for_session("tool-a", "acp-session-a");
    let (req_b, rx_b) = permission_request_for_session("tool-b", "acp-session-b");

    unwrap_ok(bridge_a.tx.send(req_a).await, "send a");
    unwrap_ok(bridge_b.tx.send(req_b).await, "send b");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let batches_a = bridge_a.pending_batches();
    let batches_b = bridge_b.pending_batches();
    assert_eq!(batches_a.len(), 1);
    assert_eq!(batches_b.len(), 1);
    assert_eq!(batches_a[0].acp_id, "acp-1");
    assert_eq!(
        batches_a[0].session_id,
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
    );
    assert_eq!(batches_b[0].acp_id, "acp-2");
    assert_eq!(
        batches_b[0].session_id,
        "00b4a39f-719e-5418-abe8-eb3ab6ea614d"
    );
    assert_ne!(batches_a[0].batch_id, batches_b[0].batch_id);
    assert_eq!(
        batches_a[0].requests[0].session_id,
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
    );
    assert_eq!(
        batches_b[0].requests[0].session_id,
        "00b4a39f-719e-5418-abe8-eb3ab6ea614d"
    );
    assert!(
        batches_a[0].requests[0]
            .request_id
            .starts_with(&batches_a[0].batch_id)
    );
    assert!(
        batches_b[0].requests[0]
            .request_id
            .starts_with(&batches_b[0].batch_id)
    );
    assert_ne!(
        batches_a[0].requests[0].request_id,
        batches_b[0].requests[0].request_id
    );
    assert!(
        batches_a[0].requests[0]
            .tool_call
            .to_string()
            .contains("tool-a")
    );
    assert!(
        batches_b[0].requests[0]
            .tool_call
            .to_string()
            .contains("tool-b")
    );

    let seen_sessions = permission_requested_sessions(&mut events);
    assert_eq!(
        seen_sessions,
        [
            "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
        ]
    );
    let _ = bridge_a.resolve_batch(&batches_a[0].batch_id, &AcpPermissionDecision::ApproveAll);
    let _ = bridge_b.resolve_batch(&batches_b[0].batch_id, &AcpPermissionDecision::ApproveAll);
    let _ = unwrap_ok(
        recv_permission_result(rx_a).await,
        "rx_a should be approved",
    );
    let _ = unwrap_ok(
        recv_permission_result(rx_b).await,
        "rx_b should be approved",
    );
}

#[tokio::test]
async fn coalesced_batches_normalize_request_sessions_to_logical_session() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (req_a, rx_a) = permission_request_for_session("tool-a", "acp-session-a");
    let (req_b, rx_b) = permission_request_for_session("tool-b", "acp-session-b");

    unwrap_ok(bridge.tx.send(req_a).await, "send a");
    unwrap_ok(bridge.tx.send(req_b).await, "send b");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let batches = bridge.pending_batches();
    assert_eq!(batches.len(), 1);
    assert_eq!(
        batches[0].session_id,
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
    );
    assert_eq!(batches[0].requests.len(), 2);
    assert!(
        batches[0]
            .requests
            .iter()
            .all(|request| request.session_id == "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
    );

    let _ = bridge.resolve_batch(&batches[0].batch_id, &AcpPermissionDecision::ApproveAll);
    let _ = unwrap_ok(
        recv_permission_result(rx_a).await,
        "rx_a should be approved",
    );
    let _ = unwrap_ok(
        recv_permission_result(rx_b).await,
        "rx_b should be approved",
    );
}

#[tokio::test]
async fn rejects_past_cap() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let mut receivers = Vec::new();

    for i in 0..9 {
        let (request, rx) = permission_request(&format!("tool-{i}"));
        unwrap_ok(bridge.tx.send(request).await, "send request");
        receivers.push(rx);
    }
    tokio::time::sleep(Duration::from_millis(20)).await;

    assert_eq!(bridge.pending_permission_count(), DEFAULT_PERMISSION_CAP);
    let rejected = unwrap_err(
        unwrap_ok(
            unwrap_some(receivers.pop(), "ninth receiver").await,
            "ninth response channel should stay open",
        ),
        "ninth rejected",
    );
    assert_eq!(rejected.code, PERMISSION_CAP_REACHED);
    bridge.shutdown_pending();
}

#[tokio::test]
async fn queue_depth_counts_requests_waiting_for_coalesce() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (request, _rx) = permission_request("tool-a");
    let (queued_request, _queued_rx) = permission_request("tool-b");

    unwrap_ok(bridge.tx.send(request).await, "send request");
    tokio::time::sleep(Duration::from_millis(1)).await;
    unwrap_ok(bridge.tx.send(queued_request).await, "send queued request");

    assert_eq!(bridge.queue_depth(), 1);
    bridge.shutdown_pending();
}

#[tokio::test]
async fn shutdown_errors_queued_requests_before_they_become_batches() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (request, rx) = permission_request("tool-a");

    unwrap_ok(bridge.tx.send(request).await, "send request");
    bridge.shutdown_pending();
    tokio::task::yield_now().await;

    let error = unwrap_err(
        recv_permission_result(rx).await,
        "queued request should receive daemon shutdown",
    );
    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[tokio::test]
async fn shutdown_errors_pending_requests() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (request, rx) = permission_request("tool-a");

    unwrap_ok(bridge.tx.send(request).await, "send request");
    tokio::time::sleep(Duration::from_millis(20)).await;
    bridge.shutdown_pending();

    let error = unwrap_err(recv_permission_result(rx).await, "shutdown error");
    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[tokio::test]
async fn shutdown_cancels_pending_expiration_tasks_without_timeout() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(40);

    unwrap_ok(bridge.tx.send(request).await, "send request");
    tokio::time::sleep(Duration::from_millis(20)).await;
    bridge.shutdown_pending();
    assert_eq!(bridge.expiration_task_count(), 0);

    let error = unwrap_err(
        recv_permission_result(rx).await,
        "shutdown should fail pending batch",
    );
    assert_eq!(error.code, DAEMON_SHUTDOWN);

    tokio::time::sleep(Duration::from_millis(60)).await;
    let mut saw_shutdown = false;
    let mut saw_timeout = false;
    for _ in 0..8 {
        let Ok(event) = receiver.try_recv() else {
            continue;
        };
        saw_shutdown |= event.event == "acp_permission_shutdown";
        saw_timeout |= event.event == "acp_permission_timeout";
    }
    assert!(saw_shutdown, "shutdown should broadcast removal event");
    assert!(
        !saw_timeout,
        "shutdown should suppress later timeout events"
    );
}

#[tokio::test]
async fn timeout_removes_pending_batch_and_broadcasts_removal() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(10);

    unwrap_ok(bridge.tx.send(request).await, "send request");
    tokio::time::sleep(Duration::from_millis(30)).await;

    let error = unwrap_err(recv_permission_result(rx).await, "permission timeout");
    assert_eq!(error.code, PERMISSION_TIMEOUT);
    assert_eq!(bridge.pending_permission_count(), 0);
    assert_eq!(bridge.expiration_task_count(), 0);
    let saw_timeout = (0..4).any(|_| {
        receiver
            .try_recv()
            .is_ok_and(|event| event.event == "acp_permission_timeout")
    });
    assert!(saw_timeout, "timeout should broadcast removal event");
}

#[tokio::test]
async fn zero_deadline_timeouts_leave_no_stale_expiration_handles() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );

    for index in 0..8 {
        let (mut request, rx) = permission_request(&format!("tool-{index}"));
        request.deadline = Duration::ZERO;

        unwrap_ok(bridge.tx.send(request).await, "send request");
        let error = unwrap_err(recv_permission_result(rx).await, "permission timeout");
        assert_eq!(error.code, PERMISSION_TIMEOUT);
        assert_eq!(bridge.expiration_task_count(), 0);
    }
}

#[tokio::test]
async fn requested_batches_include_absolute_expiration_timestamp() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (mut request, _rx) = permission_request("tool-a");
    request.deadline = Duration::from_secs(45);

    unwrap_ok(bridge.tx.send(request).await, "send request");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let requested = unwrap_some(
        (0..4).find_map(|_| receiver.try_recv().ok()),
        "permission request event",
    );
    assert_eq!(requested.event, "acp_permission_requested");
    let expires_at = unwrap_some(
        requested
            .payload
            .get("expires_at")
            .and_then(|value| value.as_str()),
        "expires_at should be present",
    );
    let created_at = unwrap_some(
        requested
            .payload
            .get("created_at")
            .and_then(|value| value.as_str()),
        "created_at should be present",
    );
    assert_ne!(
        expires_at, created_at,
        "absolute deadline should not collapse to the created_at timestamp"
    );
}

#[tokio::test]
async fn permission_bridge_cancel_on_drop_rejects_pending_batches_without_timeout() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "acp-1".into(),
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        sender,
    );
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(40);

    unwrap_ok(bridge.tx.send(request).await, "send request");
    tokio::time::sleep(Duration::from_millis(20)).await;
    drop(bridge);

    let error = unwrap_err(
        recv_permission_result(rx).await,
        "drop should fail pending batch",
    );
    assert_eq!(error.code, DAEMON_SHUTDOWN);

    tokio::time::sleep(Duration::from_millis(60)).await;
    let mut saw_shutdown = false;
    let mut saw_timeout = false;
    for _ in 0..8 {
        let Ok(event) = receiver.try_recv() else {
            continue;
        };
        saw_shutdown |= event.event == "acp_permission_shutdown";
        saw_timeout |= event.event == "acp_permission_timeout";
    }
    assert!(saw_shutdown, "drop should broadcast shutdown removal");
    assert!(!saw_timeout, "drop should cancel expiration tasks");
}

fn permission_requested_sessions(receiver: &mut broadcast::Receiver<StreamEvent>) -> Vec<String> {
    let mut sessions = Vec::new();
    for _ in 0..8 {
        let Ok(event) = receiver.try_recv() else {
            continue;
        };
        if event.event == "acp_permission_requested"
            && let Some(session_id) = event.session_id
        {
            sessions.push(session_id);
        }
    }
    sessions.sort();
    sessions
}
