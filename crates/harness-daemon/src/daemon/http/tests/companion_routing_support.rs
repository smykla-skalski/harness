//! Upstream doubles and state builders for the companion routing tests.
//!
//! These live beside the assertions rather than inside them so the test file
//! stays within the source-size limit as the routing seam grows its coverage.

use std::convert::Infallible;
use std::future::pending;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::Request;
use axum::extract::ws::{Message, WebSocketUpgrade};
use axum::http::{
    HeaderMap, Response, Uri, Version, header::AUTHORIZATION, header::CONTENT_LENGTH,
};
use axum::routing::{any, get};
use axum::{Json, Router};
use futures_util::{StreamExt as _, stream};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tokio::time::Duration;

use crate::daemon::http::companion::CompanionAuthToken;
use crate::daemon::http::{
    CompanionRouteConfig, CompanionRouter, DaemonHttpState, RemoteRequestLimitConfig,
};

use super::remote_limits_support::{remote_state_with_viewer, remote_state_with_viewer_config};

const COMPANION_PREFIX: &str = "/panel";
pub(super) const COMPANION_TOKEN: &str = "daemon-panel-test-token-0123456789";

/// What the companion saw: the request line and the headers the assertions care
/// about, echoed back as JSON so the test reads them from the daemon's answer.
async fn echo_request(uri: Uri, headers: HeaderMap, request: Request) -> Json<Value> {
    let observed: serde_json::Map<String, Value> = headers
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.as_str().to_owned(), Value::String(value.to_owned())))
        })
        .collect();
    Json(serde_json::json!({
        "is_http1": request.version() == Version::HTTP_11,
        "is_http2": request.version() == Version::HTTP_2,
        "path_and_query": uri.path_and_query().map(ToString::to_string),
        "headers": Value::Object(observed),
        "authorization_count": headers.get_all("authorization").iter().count(),
    }))
}

pub(super) async fn spawn_companion_upstream() -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind companion upstream");
    let address = listener.local_addr().expect("companion upstream address");
    let app = Router::new().fallback(any(echo_request));
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve companion upstream");
    });
    (format!("http://{address}"), server)
}

/// A companion that speaks websocket on one route.
///
/// It sends back the `Authorization` the handshake arrived with, which is what
/// lets a test prove the daemon presented its own companion credential rather
/// than passing the caller's through.
pub(super) async fn spawn_companion_websocket_upstream() -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind companion upstream");
    let address = listener.local_addr().expect("companion upstream address");
    let app = Router::new()
        .route("/panel/socket", get(companion_socket))
        .route("/panel/socket-refused", get(refuse_socket));
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve companion upstream");
    });
    (format!("http://{address}"), server)
}

async fn companion_socket(headers: HeaderMap, ws: WebSocketUpgrade) -> Response<Body> {
    let authorization = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    ws.on_upgrade(move |mut socket| async move {
        let _ = socket.send(Message::Text(authorization.into())).await;
    })
}

/// A companion that will not upgrade this caller, answering the way the panel
/// answers a browser with no session.
async fn refuse_socket() -> Response<Body> {
    Response::builder()
        .status(401)
        .header("www-authenticate", "Bearer")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"error":{"code":"unauthenticated","message":"sign in"}}"#,
        ))
        .expect("a refusal")
}

/// A port nothing is listening on: bind, read the address, then drop the
/// listener so the connect attempt is refused rather than hanging.
pub(super) async fn closed_loopback_origin() -> String {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind throwaway listener");
    let address = listener.local_addr().expect("throwaway address");
    drop(listener);
    format!("http://{address}")
}

pub(super) fn state_with_companion(upstream: &str) -> DaemonHttpState {
    let mut state = remote_state_with_viewer();
    let token = CompanionAuthToken::parse(COMPANION_TOKEN).expect("valid companion token");
    let config = CompanionRouteConfig::new(upstream, COMPANION_PREFIX, token)
        .expect("valid companion config");
    state.companion = Some(CompanionRouter::new(config));
    state
}

/// A companion that owns the whole origin, which is what `--companion-path-prefix /`
/// configures.
pub(super) fn state_with_root_companion(upstream: &str) -> DaemonHttpState {
    let mut state = remote_state_with_viewer();
    let token = CompanionAuthToken::parse(COMPANION_TOKEN).expect("valid companion token");
    let config = CompanionRouteConfig::new(upstream, "/", token).expect("valid companion config");
    state.companion = Some(CompanionRouter::new(config));
    state
}

pub(super) fn state_with_companion_limits(
    upstream: &str,
    global_concurrency: usize,
    companion_concurrency: usize,
) -> DaemonHttpState {
    let mut state = remote_state_with_viewer_config(RemoteRequestLimitConfig {
        max_http_concurrency: global_concurrency,
        request_timeout: Duration::from_secs(5),
        ..RemoteRequestLimitConfig::default()
    });
    let token = CompanionAuthToken::parse(COMPANION_TOKEN).expect("valid companion token");
    let config = CompanionRouteConfig::new(upstream, COMPANION_PREFIX, token)
        .expect("valid companion config");
    state.companion = Some(CompanionRouter::with_request_limit_for_tests(
        config,
        companion_concurrency,
    ));
    state
}

pub(super) async fn spawn_stalled_companion_upstream() -> (String, Arc<Notify>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind stalled companion");
    let address = listener.local_addr().expect("stalled companion address");
    let started = Arc::new(Notify::new());
    let observed = Arc::clone(&started);
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept companion request");
        observed.notify_one();
        let _socket = socket;
        pending::<()>().await;
    });
    (format!("http://{address}"), started, server)
}

async fn stall_after_headers() -> Response<Body> {
    let body =
        stream::iter([Ok::<_, Infallible>(Bytes::from_static(b"x"))]).chain(stream::pending());
    Response::builder()
        .header(CONTENT_LENGTH, "5")
        .body(Body::from_stream(body))
        .expect("stalled response")
}

pub(super) async fn spawn_body_stalled_companion_upstream() -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind body-stalled companion");
    let address = listener
        .local_addr()
        .expect("body-stalled companion address");
    let app = Router::new().fallback(any(stall_after_headers));
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve body-stalled companion");
    });
    (format!("http://{address}"), server)
}

pub(super) fn header(body: &Value, name: &str) -> Option<String> {
    body.get("headers")?
        .get(name)?
        .as_str()
        .map(ToOwned::to_owned)
}
