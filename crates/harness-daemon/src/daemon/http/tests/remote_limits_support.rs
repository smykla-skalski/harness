use std::sync::Arc;

use axum::extract::Extension;
use axum::http::{HeaderValue, StatusCode, header::AUTHORIZATION};
use axum::{Router, middleware, routing::get};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;

use crate::daemon::http::{
    DaemonHttpAuthMode, DaemonHttpState, RemoteRequestLimitConfig, RemoteRequestLimits,
};
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::{
    RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration, RemoteStoredAuditEvent,
};

use super::test_http_state_with_db;

pub(super) fn remote_state_with_viewer() -> DaemonHttpState {
    remote_state_with_viewer_config(RemoteRequestLimitConfig::default())
}

pub(super) fn remote_state_with_viewer_config(config: RemoteRequestLimitConfig) -> DaemonHttpState {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_domain = Some("daemon.example.com".to_string());
    state.remote_request_limits =
        Some(RemoteRequestLimits::new(config).expect("valid remote request limits"));
    let registration = RemoteClientRegistration::new_for_tests(
        "viewer",
        "Viewer",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        &remote_token("viewer"),
        "2026-07-12T08:30:00Z",
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

#[derive(Clone)]
pub(super) struct BlockingRequest {
    pub(super) started: Arc<Notify>,
    pub(super) release: Arc<Notify>,
}

async fn blocking_handler(Extension(blocking): Extension<BlockingRequest>) -> StatusCode {
    let released = blocking.release.notified();
    tokio::pin!(released);
    blocking.started.notify_one();
    released.await;
    StatusCode::OK
}

pub(super) fn remote_limit_test_router(
    state: DaemonHttpState,
    blocking: BlockingRequest,
) -> Router<()> {
    Router::new()
        .route(http_paths::HEALTH, get(blocking_handler))
        .layer(Extension(blocking))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            super::super::auth::authorize_remote_http_request,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            super::super::remote_limits::limit_remote_http_body,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            super::super::remote_limits::admit_remote_http_request,
        ))
        .with_state(state)
}

pub(super) async fn send_remote_health(
    client: reqwest::Client,
    base_url: String,
    request_id: &'static str,
) -> Result<reqwest::Response, reqwest::Error> {
    client
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", request_id)
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
}

pub(super) async fn send_stalled_remote_body(base_url: &str) -> String {
    let address = base_url.strip_prefix("http://").expect("HTTP base URL");
    let mut stream = TcpStream::connect(address)
        .await
        .expect("connect stalled request");
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {address}\r\n{client_header}: viewer\r\nAuthorization: Bearer {token}\r\nx-request-id: limit-timeout-viewer\r\nContent-Length: 10\r\nConnection: close\r\n\r\nx",
        path = http_paths::HEALTH,
        client_header = REMOTE_CLIENT_ID_HEADER,
        token = remote_token("viewer"),
    );
    stream
        .write_all(request.as_bytes())
        .await
        .expect("write stalled request");
    let mut response = Vec::new();
    timeout(Duration::from_secs(2), stream.read_to_end(&mut response))
        .await
        .expect("stalled request response timeout")
        .expect("read stalled request response");
    String::from_utf8_lossy(&response).into_owned()
}

pub(super) fn audit_for_request(
    state: &DaemonHttpState,
    request_id: &str,
) -> RemoteStoredAuditEvent {
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .load_remote_audit_events(20)
        .expect("load remote audits")
        .into_iter()
        .find(|event| event.request_id.as_deref() == Some(request_id))
        .unwrap_or_else(|| panic!("missing remote audit for {request_id}"))
}

pub(super) fn assert_allowed_limit_failure(audit: &RemoteStoredAuditEvent, error_detail: &str) {
    assert_eq!(audit.client_id.as_deref(), Some("viewer"));
    assert_eq!(audit.route_or_method, format!("GET {}", http_paths::HEALTH));
    assert_eq!(audit.scope, RemoteAccessScope::Read);
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(audit.error_detail.as_deref(), Some(error_detail));
}

pub(super) fn remote_token(client_id: &str) -> String {
    format!("token-{client_id}-abcdefghijklmnopqrstuvwxyz0123456789")
}

pub(super) fn remote_ws_request(
    base_url: &str,
    client_id: &str,
    request_id: &str,
) -> axum::http::Request<()> {
    let mut request = format!(
        "{}{path}",
        base_url.replacen("http", "ws", 1),
        path = http_paths::WS
    )
    .into_client_request()
    .expect("websocket request");
    request.headers_mut().insert(
        REMOTE_CLIENT_ID_HEADER,
        HeaderValue::from_str(client_id).expect("remote client id"),
    );
    request.headers_mut().insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {}", remote_token(client_id)))
            .expect("remote bearer token"),
    );
    request.headers_mut().insert(
        "x-request-id",
        HeaderValue::from_str(request_id).expect("request id"),
    );
    request
}

pub(super) async fn serve_remote(state: DaemonHttpState) -> (String, JoinHandle<()>) {
    serve_remote_app(super::super::daemon_http_router(state)).await
}

pub(super) async fn serve_remote_app(app: Router<()>) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind remote test listener");
    let addr = listener.local_addr().expect("listener address");
    let app = app.into_make_service_with_connect_info::<crate::daemon::http::DaemonConnectInfo>();
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve remote router");
    });
    (format!("http://{addr}"), server)
}

pub(super) async fn stop_server(server: JoinHandle<()>) {
    server.abort();
    let _ = server.await;
}
