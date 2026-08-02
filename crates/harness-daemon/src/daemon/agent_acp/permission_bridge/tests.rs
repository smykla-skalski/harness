use tokio::sync::broadcast;

use super::test_support::{
    coalesced_batch, expiration_tasks, next_broadcast, next_event, pending_permissions,
    permission_request, permission_request_for_session, permission_requested_sessions,
    recv_permission_result, unwrap_err, unwrap_ok, unwrap_some,
};
use super::*;
use crate::agents::acp::permission::standard_permission_options;

#[test]
fn runtime_permission_options_match_protocol_wire_schema() {
    for option in standard_permission_options() {
        let runtime_json = unwrap_ok(serde_json::to_value(&option), "runtime serialization");
        let wire = permission_option_to_wire(&option);
        let wire_json = unwrap_ok(serde_json::to_value(wire), "wire serialization");
        assert_eq!(wire_json, runtime_json);
    }
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

    let batches = coalesced_batch(&bridge, 2).await;
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

    let batches_a = coalesced_batch(&bridge_a, 1).await;
    let batches_b = coalesced_batch(&bridge_b, 1).await;
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

    let seen_sessions = permission_requested_sessions(&mut events, 2).await;
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

    let batches = coalesced_batch(&bridge, 2).await;
    assert_eq!(
        batches[0].session_id,
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
    );
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
    pending_permissions(&bridge, DEFAULT_PERMISSION_CAP).await;
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

// Paused time holds the bridge's coalesce window open across the assertion. On
// the wall clock the queued request is only observable for those few
// milliseconds, so a loaded host could look after the window had drained it.
#[tokio::test(start_paused = true)]
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
    pending_permissions(&bridge, 1).await;
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
    expiration_tasks(&bridge, 1).await;
    bridge.shutdown_pending();
    expiration_tasks(&bridge, 0).await;

    let error = unwrap_err(
        recv_permission_result(rx).await,
        "shutdown should fail pending batch",
    );
    assert_eq!(error.code, DAEMON_SHUTDOWN);

    assert!(
        !timeout_event_survives(&mut receiver, "acp_permission_shutdown").await,
        "shutdown should suppress later timeout events"
    );
}

/// Waits for `removal` to be broadcast, then waits past the request deadline so a
/// timeout event would already have landed had its expiration task survived.
/// Reports whether one did.
async fn timeout_event_survives(
    receiver: &mut broadcast::Receiver<StreamEvent>,
    removal: &str,
) -> bool {
    let mut saw_timeout = false;
    loop {
        let event = next_broadcast(receiver).await;
        saw_timeout |= event.event == "acp_permission_timeout";
        if event.event == removal {
            break;
        }
    }
    tokio::time::sleep(Duration::from_millis(60)).await;
    while let Ok(event) = receiver.try_recv() {
        saw_timeout |= event.event == "acp_permission_timeout";
    }
    saw_timeout
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

    let error = unwrap_err(recv_permission_result(rx).await, "permission timeout");
    assert_eq!(error.code, PERMISSION_TIMEOUT);
    pending_permissions(&bridge, 0).await;
    expiration_tasks(&bridge, 0).await;
    let _ = next_event(&mut receiver, "acp_permission_timeout").await;
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
        expiration_tasks(&bridge, 0).await;
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

    let requested = next_event(&mut receiver, "acp_permission_requested").await;
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
    expiration_tasks(&bridge, 1).await;
    drop(bridge);

    let error = unwrap_err(
        recv_permission_result(rx).await,
        "drop should fail pending batch",
    );
    assert_eq!(error.code, DAEMON_SHUTDOWN);

    assert!(
        !timeout_event_survives(&mut receiver, "acp_permission_shutdown").await,
        "drop should cancel expiration tasks"
    );
}
