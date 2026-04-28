use std::sync::mpsc::sync_channel;

use agent_client_protocol::schema::{
    RequestPermissionRequest, ToolCallUpdate, ToolCallUpdateFields,
};
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::permission::standard_permission_options;

fn permission_request(
    id: &str,
) -> (
    PermissionBridgeRequest,
    std::sync::mpsc::Receiver<PermissionBridgeResult>,
) {
    let (tx, rx) = sync_channel(1);
    let tool_call = ToolCallUpdate::new(id.to_string(), ToolCallUpdateFields::new());
    let request =
        RequestPermissionRequest::new("acp-session", tool_call, standard_permission_options());
    (
        PermissionBridgeRequest {
            request,
            deadline: Duration::from_secs(30),
            response_tx: tx,
        },
        rx,
    )
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
    assert!(rx_a.recv().expect("response a").is_ok());
    assert!(rx_b.recv().expect("response b").is_ok());
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
        .recv()
        .expect("ninth response")
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

    let received = tokio::time::timeout(
        Duration::from_millis(100),
        tokio::task::spawn_blocking(move || rx.recv()),
    )
    .await
    .expect("queued response should arrive after shutdown")
    .expect("queued response wait should not panic");
    let error = received
        .expect("queued response")
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

    let error = rx
        .recv()
        .expect("shutdown response")
        .expect_err("shutdown error");
    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[tokio::test]
async fn timeout_removes_pending_batch_and_broadcasts_removal() {
    let (sender, mut receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn("acp-1".into(), "sess-1".into(), sender);
    let (mut request, rx) = permission_request("tool-a");
    request.deadline = Duration::from_millis(10);

    bridge.tx.send(request).await.expect("send request");
    tokio::time::sleep(Duration::from_millis(30)).await;

    let received = tokio::time::timeout(
        Duration::from_millis(100),
        tokio::task::spawn_blocking(move || rx.recv()),
    )
    .await
    .expect("timeout response should arrive")
    .expect("timeout response wait should not panic");
    let error = received
        .expect("timeout response")
        .expect_err("permission timeout");
    assert_eq!(error.code, PERMISSION_TIMEOUT);
    assert_eq!(bridge.pending_permission_count(), 0);
    let saw_timeout = (0..4).any(|_| {
        receiver
            .try_recv()
            .is_ok_and(|event| event.event == "acp_permission_timeout")
    });
    assert!(saw_timeout, "timeout should broadcast removal event");
}
