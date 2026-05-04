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

async fn recv_permission_result(
    rx: oneshot::Receiver<PermissionBridgeResult>,
) -> PermissionBridgeResult {
    tokio::time::timeout(Duration::from_millis(100), rx)
        .await
        .expect("permission response should arrive")
        .expect("permission response channel should stay open")
}

#[tokio::test]
async fn coalesces_concurrent_requests_into_one_batch() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (req_a, rx_a) = permission_request("tool-a");
    let (req_b, rx_b) = permission_request("tool-b");

    bridge.tx.send(req_a).await.expect("send a");
    bridge.tx.send(req_b).await.expect("send b");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let batches = bridge.pending_batches();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].requests.len(), 2);
    let _ = bridge.resolve_batch(&batches[0].batch_id, &AcpPermissionDecision::ApproveAll);
    assert_eq!(bridge.expiration_task_count(), 0);
    assert!(recv_permission_result(rx_a).await.is_ok());
    assert!(recv_permission_result(rx_b).await.is_ok());
}

#[tokio::test]
async fn separate_logical_sessions_never_coalesce_permission_batches() {
    let (sender, mut events) = broadcast::channel(8);
    let bridge_a = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender.clone());
    let bridge_b = PermissionBridgeHandle::spawn("acp-2".into(), "sess-2".into(), sender);
    let (req_a, rx_a) = permission_request_for_session("tool-a", "acp-session-a");
    let (req_b, rx_b) = permission_request_for_session("tool-b", "acp-session-b");

    bridge_a.tx.send(req_a).await.expect("send a");
    bridge_b.tx.send(req_b).await.expect("send b");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let batches_a = bridge_a.pending_batches();
    let batches_b = bridge_b.pending_batches();
    assert_eq!(batches_a.len(), 1);
    assert_eq!(batches_b.len(), 1);
    assert_eq!(batches_a[0].acp_id, "acp-1");
    assert_eq!(batches_a[0].session_id, "sess-1");
    assert_eq!(batches_b[0].acp_id, "acp-2");
    assert_eq!(batches_b[0].session_id, "sess-2");
    assert_ne!(batches_a[0].batch_id, batches_b[0].batch_id);
    assert_eq!(batches_a[0].requests[0].session_id, "acp-session-a");
    assert_eq!(batches_b[0].requests[0].session_id, "acp-session-b");
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
    assert_eq!(seen_sessions, ["sess-1", "sess-2"]);
    let _ = bridge_a.resolve_batch(&batches_a[0].batch_id, &AcpPermissionDecision::ApproveAll);
    let _ = bridge_b.resolve_batch(&batches_b[0].batch_id, &AcpPermissionDecision::ApproveAll);
    assert!(recv_permission_result(rx_a).await.is_ok());
    assert!(recv_permission_result(rx_b).await.is_ok());
}

#[tokio::test]
async fn rejects_past_cap() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let mut receivers = Vec::new();

    for i in 0..9 {
        let (request, rx) = permission_request(&format!("tool-{i}"));
        bridge.tx.send(request).await.expect("send request");
        receivers.push(rx);
    }
    tokio::time::sleep(Duration::from_millis(20)).await;

    assert_eq!(bridge.pending_permission_count(), DEFAULT_PERMISSION_CAP);
    let rejected = receivers
        .pop()
        .expect("ninth receiver")
        .await
        .expect("ninth response channel should stay open")
        .expect_err("ninth rejected");
    assert_eq!(rejected.code, PERMISSION_CAP_REACHED);
    bridge.shutdown_pending();
}

#[tokio::test]
async fn queue_depth_counts_requests_waiting_for_coalesce() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (request, _rx) = permission_request("tool-a");
    let (queued_request, _queued_rx) = permission_request("tool-b");

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(1)).await;
    bridge
        .tx
        .send(queued_request)
        .await
        .expect("send queued request");

    assert_eq!(bridge.queue_depth(), 1);
    bridge.shutdown_pending();
}

#[tokio::test]
async fn shutdown_errors_queued_requests_before_they_become_batches() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (request, rx) = permission_request("tool-a");

    bridge.tx.send(request).await.expect("send request");
    bridge.shutdown_pending();
    tokio::task::yield_now().await;

    let error = recv_permission_result(rx)
        .await
        .expect_err("queued request should receive daemon shutdown");
    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[tokio::test]
async fn shutdown_errors_pending_requests() {
    let (sender, _) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (request, rx) = permission_request("tool-a");

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(20)).await;
    bridge.shutdown_pending();

    let error = recv_permission_result(rx)
        .await
        .expect_err("shutdown error");
    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[tokio::test]
async fn shutdown_cancels_pending_expiration_tasks_without_timeout() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(40);

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(20)).await;
    bridge.shutdown_pending();
    assert_eq!(bridge.expiration_task_count(), 0);

    let error = recv_permission_result(rx)
        .await
        .expect_err("shutdown should fail pending batch");
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
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(10);

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(30)).await;

    let error = recv_permission_result(rx)
        .await
        .expect_err("permission timeout");
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
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);

    for index in 0..8 {
        let (mut request, rx) = permission_request(&format!("tool-{index}"));
        request.deadline = Duration::ZERO;

        bridge.tx.send(request).await.expect("send request");
        let error = recv_permission_result(rx)
            .await
            .expect_err("permission timeout");
        assert_eq!(error.code, PERMISSION_TIMEOUT);
        assert_eq!(bridge.expiration_task_count(), 0);
    }
}

#[tokio::test]
async fn requested_batches_include_absolute_expiration_timestamp() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (mut request, _rx) = permission_request("tool-a");
    request.deadline = Duration::from_secs(45);

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(20)).await;

    let requested = (0..4)
        .find_map(|_| receiver.try_recv().ok())
        .expect("permission request event");
    assert_eq!(requested.event, "acp_permission_requested");
    let expires_at = requested
        .payload
        .get("expires_at")
        .and_then(|value| value.as_str())
        .expect("expires_at should be present");
    let created_at = requested
        .payload
        .get("created_at")
        .and_then(|value| value.as_str())
        .expect("created_at should be present");
    assert_ne!(
        expires_at, created_at,
        "absolute deadline should not collapse to the created_at timestamp"
    );
}

#[tokio::test]
async fn permission_bridge_cancel_on_drop_rejects_pending_batches_without_timeout() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(40);

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(20)).await;
    drop(bridge);

    let error = recv_permission_result(rx)
        .await
        .expect_err("drop should fail pending batch");
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
