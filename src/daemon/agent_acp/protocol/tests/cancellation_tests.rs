//! Wire tests for the client-request handlers: a pending permission must not
//! stall the rest of the connection, and `$/cancel_request` must release it.

use std::path::PathBuf;
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    ReadTextFileRequest, RequestPermissionOutcome, RequestPermissionRequest, ToolCallUpdate,
    ToolCallUpdateFields,
};
use agent_client_protocol::{Agent as AgentRole, Channel, ConnectionTo};
use tokio::sync::{broadcast, oneshot};

use super::super::context::ProtocolContext;
use super::super::handlers::{ClientHandlers, connect_with_client_handlers};
use super::super::session_guard::{RouteTarget, SessionRouteGuard};
use super::*;
use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::permission::standard_permission_options;
use crate::daemon::agent_acp::permission_bridge::PermissionBridgeHandle;
use crate::hooks::runner_policy::managed_cluster_binaries;

const ACP_SESSION: &str = "acp-session-1";

struct HandlerHarness {
    handlers: ClientHandlers,
    _bridge: PermissionBridgeHandle,
    readable: PathBuf,
    _project: tempfile::TempDir,
    _supervisor_child: ChildGuard,
}

/// Build the real harness client handler set over a permission bridge that
/// nobody answers, so a permission request stays outstanding for the whole
/// test unless cancellation releases it.
fn handler_harness() -> HandlerHarness {
    let project = ok(tempfile::tempdir(), "project tempdir");
    let readable = project.path().join("readable.txt");
    ok(std::fs::write(&readable, "contents"), "seed readable file");
    let supervisor_child = ChildGuard(ok(
        Command::new("sleep").arg("60").spawn(),
        "spawn supervisor child",
    ));
    let supervisor = Arc::new(AcpSessionSupervisor::new(
        &supervisor_child.0,
        SupervisionConfig::default(),
    ));
    let (sender, _receiver) = broadcast::channel(8);
    let bridge = PermissionBridgeHandle::spawn(
        "agent-acp-1".to_string(),
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
        sender,
    );
    let client = Arc::new(HarnessAcpClient::new(
        project.path().to_path_buf(),
        project.path().to_path_buf(),
        None,
        managed_cluster_binaries(),
        bridge.mode(Duration::from_secs(30)),
    ));
    let session_guard = Arc::new(SessionRouteGuard::default());
    session_guard.start_session(
        &SessionId::new(ACP_SESSION),
        RouteTarget {
            acp_id: "agent-acp-1".to_string(),
            session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
        },
    );
    let (notifications, _routed) = mpsc::channel(8);
    HandlerHarness {
        handlers: ClientHandlers {
            context: ProtocolContext::new(
                client,
                Arc::clone(&supervisor),
                Arc::clone(&session_guard),
            ),
            session_guard,
            supervisor,
            manager: protocol_manager(
                "fake",
                "agent-acp-1",
                "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
            ),
            notifications,
        },
        _bridge: bridge,
        readable,
        _project: project,
        _supervisor_child: supervisor_child,
    }
}

fn permission_request() -> RequestPermissionRequest {
    RequestPermissionRequest::new(
        ACP_SESSION,
        ToolCallUpdate::new("fs.write_text_file:/tmp/x", ToolCallUpdateFields::new()),
        standard_permission_options(),
    )
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn pending_permission_does_not_stall_other_requests() {
    let harness = handler_harness();
    let readable = harness.readable.clone();
    let (client_transport, agent_transport) = Channel::duplex();
    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    let client_task = tokio::spawn(connect_with_client_handlers(
        client_transport,
        harness.handlers,
        async move |_connection: ConnectionTo<Agent>| {
            let _ = stop_rx.await;
            Ok(())
        },
    ));

    let (served_tx, served_rx) = oneshot::channel::<bool>();
    let agent_task = tokio::spawn(async move {
        AgentRole
            .builder()
            .name("cancellation-probe-agent")
            .connect_with(agent_transport, async move |connection| {
                // Leave a permission outstanding: nothing resolves the bridge
                // batch, so this only completes if the test cancels it.
                let pending = connection.send_request(permission_request());
                tokio::time::sleep(Duration::from_millis(100)).await;
                let read = connection
                    .send_request(ReadTextFileRequest::new(ACP_SESSION, readable))
                    .block_task();
                let served = tokio::time::timeout(Duration::from_secs(2), read)
                    .await
                    .is_ok_and(|result| result.is_ok());
                let _ = served_tx.send(served);
                pending.cancel()?;
                let _ = pending.block_task().await;
                Ok(())
            })
            .await
    });

    let served = ok(
        tokio::time::timeout(Duration::from_secs(5), served_rx).await,
        "read probe should report before the test deadline",
    );
    assert_eq!(
        ok(served, "read probe channel should stay open"),
        true,
        "fs/read_text_file must be served while a permission is outstanding"
    );

    let _ = stop_tx.send(());
    let _ = tokio::time::timeout(Duration::from_secs(5), client_task).await;
    agent_task.abort();
    let _ = agent_task.await;
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn cancelled_permission_request_resolves_as_cancelled() {
    let harness = handler_harness();
    let (client_transport, agent_transport) = Channel::duplex();
    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    let client_task = tokio::spawn(connect_with_client_handlers(
        client_transport,
        harness.handlers,
        async move |_connection: ConnectionTo<Agent>| {
            let _ = stop_rx.await;
            Ok(())
        },
    ));

    let (outcome_tx, outcome_rx) = oneshot::channel::<bool>();
    let agent_task = tokio::spawn(async move {
        AgentRole
            .builder()
            .name("cancelling-agent")
            .connect_with(agent_transport, async move |connection| {
                let pending = connection.send_request(permission_request());
                tokio::time::sleep(Duration::from_millis(100)).await;
                pending.cancel()?;
                let cancelled = matches!(
                    tokio::time::timeout(Duration::from_secs(5), pending.block_task()).await,
                    Ok(Ok(response))
                        if response.outcome == RequestPermissionOutcome::Cancelled
                );
                let _ = outcome_tx.send(cancelled);
                Ok(())
            })
            .await
    });

    let cancelled = ok(
        tokio::time::timeout(Duration::from_secs(10), outcome_rx).await,
        "cancelled permission should answer well before the 30s bridge deadline",
    );
    assert!(
        ok(cancelled, "outcome channel should stay open"),
        "cancelling the request must resolve the permission as cancelled"
    );

    let _ = stop_tx.send(());
    let _ = tokio::time::timeout(Duration::from_secs(5), client_task).await;
    agent_task.abort();
    let _ = agent_task.await;
}
