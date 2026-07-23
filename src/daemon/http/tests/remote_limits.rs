use std::sync::Arc;

use axum::http::StatusCode;
use futures_util::{SinkExt as _, Stream, StreamExt as _};
use rusqlite::Connection;
use tokio::sync::Notify;
use tokio::time::{Duration, timeout};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};

use crate::daemon::http::RemoteRequestLimitConfig;
use crate::daemon::http::remote_limits::DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::{RemoteAuditOutcome, RemoteAuditScopeDecision};

use super::remote_limits_support::{
    BlockingRequest, assert_allowed_limit_failure, audit_for_request, remote_limit_test_router,
    remote_state_with_viewer, remote_state_with_viewer_config, remote_token, remote_ws_request,
    send_remote_health, send_stalled_remote_body, serve_remote, serve_remote_app, stop_server,
};

const MAX_REMOTE_WEBSOCKET_CONNECTIONS: usize = 64;

#[tokio::test]
async fn remote_http_rejects_bodies_over_the_configured_limit() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "limit-body-viewer")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .body(vec![
            b'x';
            DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES + 1
        ])
        .send()
        .await
        .expect("send oversized remote request");
    let status = response.status();
    let audit = audit_state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .load_remote_audit_events(1)
        .expect("load remote audit")
        .pop()
        .expect("oversized request audit");

    stop_server(server).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(audit.request_id.as_deref(), Some("limit-body-viewer"));
    assert_eq!(audit.client_id.as_deref(), Some("viewer"));
    assert_eq!(audit.route_or_method, format!("GET {}", http_paths::HEALTH));
    assert_eq!(audit.scope, RemoteAccessScope::Read);
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        audit.error_detail.as_deref(),
        Some("remote request body exceeds the configured limit")
    );
}

#[tokio::test]
async fn remote_http_bounds_unauthenticated_bodies_before_authentication() {
    let state = remote_state_with_viewer();
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "limit-body-unauthenticated")
        .body(vec![
            b'x';
            DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES + 1
        ])
        .send()
        .await
        .expect("send unauthenticated oversized remote request");
    let status = response.status();
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("decode remote limit error");
    let audit = audit_for_request(&audit_state, "limit-body-unauthenticated");

    stop_server(server).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(body["error"]["code"], "REMOTE_LIMITS");
    assert_eq!(audit.client_id, None);
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Denied);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Failure);
}

#[tokio::test]
async fn remote_http_audits_uri_limit_rejections() {
    let config = RemoteRequestLimitConfig {
        max_http_uri_bytes: 128,
        ..RemoteRequestLimitConfig::default()
    };
    let state = remote_state_with_viewer_config(config);
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let response = reqwest::Client::new()
        .get(format!(
            "{base_url}{}?padding={}",
            http_paths::HEALTH,
            "x".repeat(256)
        ))
        .header("x-request-id", "limit-uri-viewer")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send oversized remote URI");
    let audit = audit_for_request(&audit_state, "limit-uri-viewer");

    stop_server(server).await;
    assert_eq!(response.status(), StatusCode::URI_TOO_LONG);
    assert_allowed_limit_failure(&audit, "remote request URI exceeds the configured limit");
}

#[tokio::test]
async fn remote_http_audits_header_limit_rejections() {
    let config = RemoteRequestLimitConfig {
        max_http_header_bytes: 256,
        ..RemoteRequestLimitConfig::default()
    };
    let state = remote_state_with_viewer_config(config);
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "limit-header-viewer")
        .header("x-padding", "x".repeat(512))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send oversized remote headers");
    let audit = audit_for_request(&audit_state, "limit-header-viewer");

    stop_server(server).await;
    assert_eq!(
        response.status(),
        StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE
    );
    assert_allowed_limit_failure(&audit, "remote request headers exceed the configured limit");
}

#[tokio::test]
async fn remote_http_limit_rejections_fail_closed_without_audit_storage() {
    let state = remote_state_with_viewer();
    Connection::open(state.db_path.as_ref().expect("db path"))
        .expect("open audit db")
        .execute("DROP TABLE remote_audit_events", [])
        .expect("drop remote audit table");
    let (base_url, server) = serve_remote(state).await;
    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .body(vec![
            b'x';
            DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES + 1
        ])
        .send()
        .await
        .expect("send oversized request without audit store");
    let status = response.status();
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("decode audit error");

    stop_server(server).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"]["code"], "REMOTE_AUDIT");
}

#[tokio::test]
async fn remote_http_audits_concurrency_limit_rejections() {
    let config = RemoteRequestLimitConfig {
        max_http_concurrency: 1,
        request_timeout: Duration::from_secs(5),
        ..RemoteRequestLimitConfig::default()
    };
    let state = remote_state_with_viewer_config(config);
    let audit_state = state.clone();
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let app = remote_limit_test_router(
        state,
        BlockingRequest {
            started: Arc::clone(&started),
            release: Arc::clone(&release),
        },
    );
    let (base_url, server) = serve_remote_app(app).await;
    let client = reqwest::Client::new();
    let first = tokio::spawn(send_remote_health(
        client.clone(),
        base_url.clone(),
        "limit-concurrency-first",
    ));
    timeout(Duration::from_secs(2), started.notified())
        .await
        .expect("first request reached handler");

    let overflow = send_remote_health(client, base_url, "limit-concurrency-overflow")
        .await
        .expect("send concurrency overflow");
    let retry_after = overflow
        .headers()
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);
    let audit = audit_for_request(&audit_state, "limit-concurrency-overflow");
    release.notify_waiters();
    let first_status = first
        .await
        .expect("join first request")
        .expect("send first request")
        .status();

    stop_server(server).await;
    assert_eq!(overflow.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(retry_after.as_deref(), Some("1"));
    assert_eq!(first_status, StatusCode::OK);
    assert_allowed_limit_failure(&audit, "remote request concurrency limit reached");
}

#[tokio::test]
async fn remote_http_audits_timeout_before_authentication() {
    let config = RemoteRequestLimitConfig {
        request_timeout: Duration::from_millis(100),
        ..RemoteRequestLimitConfig::default()
    };
    let state = remote_state_with_viewer_config(config);
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;

    let response = send_stalled_remote_body(&base_url).await;
    let audit = audit_for_request(&audit_state, "limit-timeout-viewer");

    stop_server(server).await;
    assert!(
        response.starts_with("HTTP/1.1 504"),
        "unexpected timeout response: {response}"
    );
    assert_allowed_limit_failure(&audit, "remote request exceeded the configured timeout");
}

#[tokio::test]
async fn remote_http_audits_timeout_after_authentication() {
    let config = RemoteRequestLimitConfig {
        request_timeout: Duration::from_millis(250),
        ..RemoteRequestLimitConfig::default()
    };
    let state = remote_state_with_viewer_config(config);
    let audit_state = state.clone();
    let started = Arc::new(Notify::new());
    let app = remote_limit_test_router(
        state,
        BlockingRequest {
            started: Arc::clone(&started),
            release: Arc::new(Notify::new()),
        },
    );
    let (base_url, server) = serve_remote_app(app).await;
    let request = tokio::spawn(send_remote_health(
        reqwest::Client::new(),
        base_url,
        "limit-timeout-after-auth",
    ));
    timeout(Duration::from_secs(2), started.notified())
        .await
        .expect("timed request reached handler");

    let response = request
        .await
        .expect("join timed request")
        .expect("send timed request");
    let audits = audit_state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .load_remote_audit_events(20)
        .expect("load remote audits")
        .into_iter()
        .filter(|event| event.request_id.as_deref() == Some("limit-timeout-after-auth"))
        .collect::<Vec<_>>();

    stop_server(server).await;
    assert_eq!(response.status(), StatusCode::GATEWAY_TIMEOUT);
    assert_eq!(audits.len(), 1, "timeout audit should update in place");
    assert_allowed_limit_failure(&audits[0], "remote request exceeded the configured timeout");
}

#[tokio::test]
async fn remote_websocket_rejects_messages_over_the_configured_limit() {
    let (base_url, server) = serve_remote(remote_state_with_viewer()).await;
    let request = remote_ws_request(&base_url, "viewer", "ws-size-handshake");
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");
    let oversized = serde_json::json!({
        "id": "oversized-ws-request",
        "method": ws_methods::PING,
        "params": { "padding": "x".repeat(DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES) },
    });
    let send_result = socket
        .send(Message::Text(oversized.to_string().into()))
        .await;
    let rejected = match send_result {
        Ok(()) => websocket_rejects_request(&mut socket, "oversized-ws-request").await,
        Err(_) => true,
    };

    let _ = socket.close(None).await;
    stop_server(server).await;
    assert!(rejected, "oversized websocket request reached dispatch");
}

#[tokio::test]
async fn remote_websocket_caps_live_connections() {
    let (base_url, server) = serve_remote(remote_state_with_viewer()).await;
    let mut sockets = Vec::with_capacity(MAX_REMOTE_WEBSOCKET_CONNECTIONS + 1);
    for index in 0..MAX_REMOTE_WEBSOCKET_CONNECTIONS {
        let request = remote_ws_request(&base_url, "viewer", &format!("ws-limit-{index}"));
        let (socket, _) = connect_async(request).await.expect("connect within limit");
        sockets.push(socket);
    }
    let overflow = connect_async(remote_ws_request(&base_url, "viewer", "ws-limit-overflow")).await;
    let overflow_status = match overflow {
        Err(WebSocketError::Http(response)) => Some(response.status()),
        Ok((socket, _)) => {
            sockets.push(socket);
            None
        }
        Err(error) => panic!("unexpected websocket overflow error: {error}"),
    };

    drop(sockets);
    stop_server(server).await;
    assert_eq!(overflow_status, Some(StatusCode::TOO_MANY_REQUESTS));
}

async fn websocket_rejects_request(
    socket: &mut (impl Stream<Item = Result<Message, WebSocketError>> + Unpin),
    request_id: &str,
) -> bool {
    timeout(Duration::from_secs(5), async {
        while let Some(frame) = socket.next().await {
            match frame {
                Ok(Message::Text(text)) => {
                    if serde_json::from_str::<serde_json::Value>(&text)
                        .ok()
                        .and_then(|value| value["id"].as_str().map(str::to_string))
                        .as_deref()
                        == Some(request_id)
                    {
                        return false;
                    }
                }
                Ok(Message::Close(_)) | Err(_) => return true,
                Ok(_) => {}
            }
        }
        true
    })
    .await
    .expect("websocket size rejection timeout")
}
