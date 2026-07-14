use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::middleware;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use futures_util::{Sink, SinkExt as _, Stream, StreamExt as _};
use rusqlite::Connection;
use serde_json::json;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};

use crate::daemon::http::{DaemonConnectInfo, DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::{
    RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration, RemoteStoredAuditEvent,
};

use super::test_http_state_with_db;

#[tokio::test]
async fn remote_authorization_audit_records_http_allow_and_deny() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;

    let allowed = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "audit-http-allowed")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send allowed request");
    assert_eq!(allowed.status(), StatusCode::OK);

    let denied = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::DAEMON_TELEMETRY))
        .header("x-request-id", "audit-http-denied")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .json(&json!({"kind": "decode_failure"}))
        .send()
        .await
        .expect("send denied request");
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);

    let events = remote_audits(&audit_state);
    let allowed = audit_for_request(&events, "audit-http-allowed");
    assert_eq!(allowed.client_id.as_deref(), Some("viewer"));
    assert_eq!(
        allowed.route_or_method,
        format!("GET {}", http_paths::HEALTH)
    );
    assert_eq!(allowed.scope, RemoteAccessScope::Read);
    assert_eq!(allowed.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(allowed.outcome, RemoteAuditOutcome::Success);
    assert_eq!(allowed.remote_addr.as_deref(), Some("127.0.0.1"));
    assert_eq!(allowed.error_detail, None);

    let denied = audit_for_request(&events, "audit-http-denied");
    assert_eq!(denied.client_id.as_deref(), Some("viewer"));
    assert_eq!(
        denied.route_or_method,
        format!("POST {}", http_paths::DAEMON_TELEMETRY)
    );
    assert_eq!(denied.scope, RemoteAccessScope::Write);
    assert_eq!(denied.scope_decision, RemoteAuditScopeDecision::Denied);
    assert_eq!(denied.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(denied.remote_addr.as_deref(), Some("127.0.0.1"));
    assert_eq!(
        denied.error_detail.as_deref(),
        Some("remote client scope is insufficient")
    );

    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_records_http_handler_failures() {
    const MISSING_SESSION_ID: &str = "00000000-0000-4000-8000-000000000001";

    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/v1/sessions/{MISSING_SESSION_ID}"))
        .header("x-request-id", "audit-http-handler-failure")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send failing authorized request");
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let events = remote_audits(&audit_state);
    let event = audit_for_request(&events, "audit-http-handler-failure");
    assert_eq!(
        event.route_or_method,
        format!("GET {}", http_paths::SESSION_DETAIL)
    );
    assert_eq!(event.scope, RemoteAccessScope::Read);
    assert_eq!(event.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(event.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        event.error_detail.as_deref(),
        Some("remote HTTP handler returned status 400")
    );
    assert!(
        !event
            .error_detail
            .as_deref()
            .unwrap_or_default()
            .contains(MISSING_SESSION_ID)
    );

    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_update_failure_preserves_http_response() {
    let state = remote_state_with_viewer();
    let app = Router::new()
        .route(http_paths::HEALTH, get(drop_audit_store_then_fail))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            super::super::auth::authorize_remote_http_request,
        ))
        .with_state(state);
    let (base_url, server) = serve_router(app).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "audit-http-update-failure")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send request whose audit update fails");
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("handler error json");
    assert_eq!(body["error"]["code"], "HANDLER_FAILURE");

    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_redacts_unauthenticated_attempts() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "audit-http-unauthenticated")
        .bearer_auth("must-not-be-persisted")
        .send()
        .await
        .expect("send unauthenticated request");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let events = remote_audits(&audit_state);
    let event = audit_for_request(&events, "audit-http-unauthenticated");
    assert_eq!(event.client_id, None);
    assert_eq!(event.scope, RemoteAccessScope::Read);
    assert_eq!(event.scope_decision, RemoteAuditScopeDecision::Denied);
    assert_eq!(event.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(event.remote_addr.as_deref(), Some("127.0.0.1"));
    assert!(
        !event
            .error_detail
            .as_deref()
            .unwrap_or_default()
            .contains("must-not-be-persisted")
    );

    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_bounds_client_controlled_request_ids() {
    const MAX_PERSISTED_REQUEST_ID_BYTES: usize = 256;

    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let oversized_request_id = "request-id-".repeat(256);

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", &oversized_request_id)
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send oversized HTTP request id");
    assert_eq!(response.status(), StatusCode::OK);

    let request = remote_ws_request(&base_url, "viewer", "audit-ws-bounded-handshake");
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");
    let response = ws_rpc(&mut socket, &oversized_request_id, ws_methods::PING).await;
    assert_eq!(response["error"], serde_json::Value::Null);

    let events = remote_audits(&audit_state);
    let http = events
        .iter()
        .find(|event| event.route_or_method == format!("GET {}", http_paths::HEALTH))
        .expect("HTTP audit event");
    assert_bounded_request_id(http, MAX_PERSISTED_REQUEST_ID_BYTES);
    let websocket = events
        .iter()
        .find(|event| event.route_or_method == ws_methods::PING)
        .expect("WebSocket audit event");
    assert_bounded_request_id(websocket, MAX_PERSISTED_REQUEST_ID_BYTES);

    let _ = socket.close(None).await;
    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_fails_closed_without_a_store() {
    let state = remote_state_with_viewer();
    drop_remote_audit_table(&state);
    let (base_url, server) = serve_remote(state).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send request without audit store");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("error json");
    assert_eq!(body["error"]["code"], "REMOTE_AUDIT");

    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_records_websocket_methods() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let request = remote_ws_request(&base_url, "viewer", "audit-ws-handshake");
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");

    let ping = ws_rpc(&mut socket, "audit-ws-read", ws_methods::PING).await;
    assert_eq!(ping["error"], serde_json::Value::Null);
    let denied = ws_rpc(&mut socket, "audit-ws-write", ws_methods::SESSION_START).await;
    assert_eq!(denied["error"]["code"], "REMOTE_AUTH");

    let events = remote_audits(&audit_state);
    let handshake = audit_for_request(&events, "audit-ws-handshake");
    assert_eq!(handshake.route_or_method, format!("GET {}", http_paths::WS));
    assert_eq!(handshake.remote_addr.as_deref(), Some("127.0.0.1"));

    let read = audit_for_request(&events, "audit-ws-read");
    assert_eq!(read.route_or_method, ws_methods::PING);
    assert_eq!(read.scope, RemoteAccessScope::Read);
    assert_eq!(read.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(read.outcome, RemoteAuditOutcome::Success);
    assert_eq!(read.remote_addr.as_deref(), Some("127.0.0.1"));

    let write = audit_for_request(&events, "audit-ws-write");
    assert_eq!(write.route_or_method, ws_methods::SESSION_START);
    assert_eq!(write.scope, RemoteAccessScope::Write);
    assert_eq!(write.scope_decision, RemoteAuditScopeDecision::Denied);
    assert_eq!(write.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(write.remote_addr.as_deref(), Some("127.0.0.1"));
    assert_eq!(
        write.error_detail.as_deref(),
        Some("remote client scope is insufficient")
    );

    let _ = socket.close(None).await;
    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_records_websocket_handler_failures() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let request = remote_ws_request(&base_url, "viewer", "audit-ws-failure-handshake");
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");

    let response = ws_rpc(
        &mut socket,
        "audit-ws-handler-failure",
        ws_methods::SESSION_DETAIL,
    )
    .await;
    assert_eq!(response["error"]["code"], "MISSING_PARAM");

    let events = remote_audits(&audit_state);
    let event = audit_for_request(&events, "audit-ws-handler-failure");
    assert_eq!(event.route_or_method, ws_methods::SESSION_DETAIL);
    assert_eq!(event.scope, RemoteAccessScope::Read);
    assert_eq!(event.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(event.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        event.error_detail.as_deref(),
        Some("remote WebSocket handler returned error MISSING_PARAM")
    );
    assert!(
        !event
            .error_detail
            .as_deref()
            .unwrap_or_default()
            .contains("session_id")
    );

    let _ = socket.close(None).await;
    stop_server(server).await;
}

#[tokio::test]
async fn remote_authorization_audit_fails_closed_websocket_dispatch() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let request = remote_ws_request(&base_url, "viewer", "audit-ws-before-drop");
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");
    drop_remote_audit_table(&audit_state);

    let response = ws_rpc(&mut socket, "audit-ws-no-store", ws_methods::PING).await;
    assert_eq!(response["result"], serde_json::Value::Null);
    assert_eq!(response["error"]["code"], "REMOTE_AUDIT");
    assert_eq!(response["error"]["status_code"], 503);

    let _ = socket.close(None).await;
    stop_server(server).await;
}

fn remote_state_with_viewer() -> DaemonHttpState {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let registration = RemoteClientRegistration::new_for_tests(
        "viewer",
        "Viewer",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        &remote_token("viewer"),
        "2026-07-12T08:00:00Z",
    )
    .expect("remote registration");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .register_remote_client(&registration)
        .expect("register viewer");
    state
}

fn remote_audits(state: &DaemonHttpState) -> Vec<RemoteStoredAuditEvent> {
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .load_remote_audit_events(20)
        .expect("load remote audits")
}

fn audit_for_request<'a>(
    events: &'a [RemoteStoredAuditEvent],
    request_id: &str,
) -> &'a RemoteStoredAuditEvent {
    events
        .iter()
        .find(|event| event.request_id.as_deref() == Some(request_id))
        .unwrap_or_else(|| panic!("missing audit for {request_id}: {events:?}"))
}

fn assert_bounded_request_id(event: &RemoteStoredAuditEvent, max_bytes: usize) {
    let request_id = event.request_id.as_deref().expect("audit request id");
    assert!(request_id.len() <= max_bytes, "oversized audit request id");
    assert!(request_id.ends_with("..."), "missing truncation marker");
}

fn drop_remote_audit_table(state: &DaemonHttpState) {
    Connection::open(state.db_path.as_ref().expect("db path"))
        .expect("open audit db")
        .execute("DROP TABLE remote_audit_events", [])
        .expect("drop remote audit table");
}

async fn drop_audit_store_then_fail(State(state): State<DaemonHttpState>) -> impl IntoResponse {
    drop_remote_audit_table(&state);
    (
        StatusCode::BAD_REQUEST,
        Json(json!({"error": {"code": "HANDLER_FAILURE"}})),
    )
}

fn remote_token(client_id: &str) -> String {
    format!("remote-token-secret-{client_id}")
}

fn remote_ws_request(base_url: &str, client_id: &str, request_id: &str) -> Request<()> {
    let mut request = format!(
        "{}{}",
        base_url.replacen("http://", "ws://", 1),
        http_paths::WS
    )
    .into_client_request()
    .expect("websocket request");
    request.headers_mut().insert(
        REMOTE_CLIENT_ID_HEADER,
        client_id.parse().expect("client id header"),
    );
    request.headers_mut().insert(
        "authorization",
        format!("Bearer {}", remote_token(client_id))
            .parse()
            .expect("authorization header"),
    );
    request.headers_mut().insert(
        "x-request-id",
        request_id.parse().expect("request id header"),
    );
    request
}

async fn ws_rpc<S>(socket: &mut S, id: &str, method: &str) -> serde_json::Value
where
    S: Sink<Message, Error = WebSocketError>
        + Stream<Item = Result<Message, WebSocketError>>
        + Unpin,
{
    timeout(Duration::from_secs(5), async {
        socket
            .send(Message::Text(
                json!({"id": id, "method": method, "params": {}})
                    .to_string()
                    .into(),
            ))
            .await
            .expect("send websocket request");
        while let Some(frame) = socket.next().await {
            let Message::Text(text) = frame.expect("read websocket frame") else {
                continue;
            };
            let value = serde_json::from_str::<serde_json::Value>(&text).expect("websocket json");
            if value["id"].as_str() == Some(id) {
                return value;
            }
        }
        panic!("missing websocket response for {id}");
    })
    .await
    .expect("websocket response timeout")
}

async fn serve_remote(state: DaemonHttpState) -> (String, JoinHandle<()>) {
    serve_router(super::super::daemon_http_router(state)).await
}

async fn serve_router(app: Router) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener address");
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<DaemonConnectInfo>(),
        )
        .await
        .expect("serve remote router");
    });
    (format!("http://{addr}"), server)
}

async fn stop_server(server: JoinHandle<()>) {
    server.abort();
    let _ = server.await;
}
