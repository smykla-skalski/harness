use std::path::Path;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use axum::http::StatusCode;
use futures_util::{SinkExt as _, StreamExt as _};
use rusqlite::TransactionBehavior;
use serde_json::json;
use tokio::time::{sleep, timeout};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{RemoteAuditOutcome, RemoteAuditScopeDecision};

use super::remote_limits_support::{
    audit_for_request, remote_state_with_viewer, remote_ws_request, send_remote_health,
    serve_remote, stop_server,
};

const AUDIT_CONTENTION_TIMEOUT: Duration = Duration::from_secs(2);

#[tokio::test(flavor = "current_thread")]
async fn remote_http_authorization_audit_yields_to_contending_writer() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let db_path = state.db_path.clone().expect("remote database path");
    let (base_url, server) = serve_remote(state).await;
    let writer = ContendingWriter::begin(&db_path);
    let release = writer.release_after(Duration::from_millis(25));

    let response = timeout(
        AUDIT_CONTENTION_TIMEOUT,
        send_remote_health(reqwest::Client::new(), base_url, "audit-http-contention"),
    )
    .await
    .expect("HTTP audit contention timed out")
    .expect("send HTTP request during audit contention");
    assert_eq!(response.status(), StatusCode::OK);

    release.finish().await;
    let audit = audit_for_request(&audit_state, "audit-http-contention");
    assert_successful_read_audit(&audit, &format!("GET {}", http_paths::HEALTH));
    stop_server(server).await;
}

#[tokio::test(flavor = "current_thread")]
async fn waiting_remote_audit_does_not_block_concurrent_authentication() {
    let state = remote_state_with_viewer();
    let db_path = state.db_path.clone().expect("remote database path");
    let (base_url, server) = serve_remote(state).await;
    let writer = ContendingWriter::begin(&db_path);
    let first_request = tokio::spawn(send_remote_health(
        reqwest::Client::new(),
        base_url.clone(),
        "audit-http-contention-first",
    ));
    sleep(Duration::from_millis(100)).await;
    let release = writer.release_after(Duration::from_millis(25));

    let second_response = timeout(
        AUDIT_CONTENTION_TIMEOUT,
        send_remote_health(
            reqwest::Client::new(),
            base_url,
            "audit-http-contention-second",
        ),
    )
    .await;
    let first_response = timeout(AUDIT_CONTENTION_TIMEOUT, first_request).await;

    release.finish().await;
    stop_server(server).await;
    let first_response = first_response
        .expect("first contending request timed out")
        .expect("join first contending request")
        .expect("send first contending request");
    let second_response = second_response
        .expect("concurrent authentication timed out")
        .expect("send concurrent authenticated request");
    assert_eq!(first_response.status(), StatusCode::OK);
    assert_eq!(second_response.status(), StatusCode::OK);
}

#[tokio::test(flavor = "current_thread")]
async fn remote_websocket_authorization_audit_yields_to_contending_writer() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let db_path = state.db_path.clone().expect("remote database path");
    let (base_url, server) = serve_remote(state).await;
    let request = remote_ws_request(&base_url, "viewer", "audit-ws-contention-handshake");
    let (mut socket, _) = connect_async(request).await.expect("connect WebSocket");
    let writer = ContendingWriter::begin(&db_path);
    let release = writer.release_after(Duration::from_millis(25));

    let response = websocket_rpc(&mut socket, "audit-ws-contention").await;
    assert_eq!(response["error"], serde_json::Value::Null);

    release.finish().await;
    let audit = audit_for_request(&audit_state, "audit-ws-contention");
    assert_successful_read_audit(&audit, ws_methods::PING);
    let _ = socket.close(None).await;
    stop_server(server).await;
}

fn assert_successful_read_audit(
    audit: &crate::daemon::remote_identity::RemoteStoredAuditEvent,
    target: &str,
) {
    assert_eq!(audit.client_id.as_deref(), Some("viewer"));
    assert_eq!(audit.route_or_method, target);
    assert_eq!(audit.scope, RemoteAccessScope::Read);
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Success);
    assert_eq!(audit.error_detail, None);
}

async fn websocket_rpc(
    socket: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    request_id: &str,
) -> serde_json::Value {
    timeout(AUDIT_CONTENTION_TIMEOUT, async {
        socket
            .send(Message::Text(
                json!({"id": request_id, "method": ws_methods::PING, "params": {}})
                    .to_string()
                    .into(),
            ))
            .await
            .expect("send WebSocket request during audit contention");
        while let Some(frame) = socket.next().await {
            let Message::Text(text) = frame.expect("read WebSocket frame") else {
                continue;
            };
            let response = serde_json::from_str::<serde_json::Value>(&text)
                .expect("deserialize WebSocket response");
            if response["id"].as_str() == Some(request_id) {
                return response;
            }
        }
        panic!("missing WebSocket response for {request_id}");
    })
    .await
    .expect("WebSocket audit contention timed out")
}

struct ContendingWriter {
    release: mpsc::Sender<()>,
    thread: thread::JoinHandle<()>,
}

impl ContendingWriter {
    fn begin(db_path: &Path) -> Self {
        let (ready_tx, ready_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let db_path = db_path.to_owned();
        let thread = thread::spawn(move || {
            let mut connection =
                rusqlite::Connection::open(db_path).expect("open contending SQLite writer");
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .expect("begin contending SQLite write transaction");
            ready_tx.send(()).expect("signal contending writer ready");
            release_rx
                .recv()
                .expect("receive contending writer release");
            transaction
                .commit()
                .expect("commit contending SQLite writer");
        });
        ready_rx.recv().expect("wait for contending SQLite writer");
        Self {
            release: release_tx,
            thread,
        }
    }

    fn release_after(self, delay: Duration) -> ScheduledWriterRelease {
        let task = tokio::spawn(async move {
            sleep(delay).await;
            self.release.send(()).expect("release contending writer");
            self.thread.join().expect("join contending SQLite writer");
        });
        ScheduledWriterRelease(task)
    }
}

struct ScheduledWriterRelease(tokio::task::JoinHandle<()>);

impl ScheduledWriterRelease {
    async fn finish(self) {
        self.0.await.expect("finish contending writer release");
    }
}
