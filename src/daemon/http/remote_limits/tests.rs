use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::Extension;
use axum::http::{Method, Request, StatusCode};
use axum::middleware;
use axum::routing::get;
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::sync::Notify;

use super::*;
use crate::daemon::protocol::http_paths;
use crate::daemon::task_board_remote_transport::routes::{
    DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES, HEARTBEAT_PATH, OFFER_HTTP_BODY_LIMIT_BYTES,
    OFFER_PATH, SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES, SOURCE_BUNDLE_ABANDON_PATH,
    SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES, SOURCE_BUNDLE_PATH, SOURCE_BUNDLE_RECEIPT_PATH,
};

#[test]
fn remote_request_limit_defaults_are_valid_and_non_zero() {
    let config = RemoteRequestLimitConfig::default();

    config.validate().expect("default remote request limits");
    assert!(config.max_http_body_bytes > 0);
    assert!(config.max_http_concurrency > 0);
    assert!(config.max_concurrent_tls_handshakes > 0);
    assert!(config.max_websocket_connections > 0);
    assert!(config.max_websocket_in_flight_requests > 0);
    assert_eq!(config.max_http_body_bytes, MAX_REMOTE_HTTP_BODY_LIMIT_BYTES);
}

#[test]
fn unauthenticated_audit_retry_after_rounds_up_to_the_full_window() {
    let limits = RemoteRequestLimits::new(RemoteRequestLimitConfig {
        unauthenticated_audit_window: Duration::from_millis(1_500),
        ..RemoteRequestLimitConfig::default()
    })
    .expect("fractional audit window");

    assert_eq!(limits.unauthenticated_audit_retry_after_seconds(), 2);
}

#[test]
fn unauthenticated_audit_limiter_recovers_from_mutex_poisoning() {
    let limits = RemoteRequestLimits::default();
    let limiter = Arc::clone(&limits.unauthenticated_audit_limiter);
    let poisoned = std::panic::catch_unwind(move || {
        let _guard = limiter.lock().expect("lock limiter before poisoning");
        panic!("poison the test limiter");
    });

    assert!(poisoned.is_err());
    assert_eq!(
        limits.admit_unauthenticated_audit("127.0.0.1"),
        RemoteUnauthenticatedAuditAdmission::Audit,
    );
}

#[test]
fn concurrency_rejection_preserves_a_longer_audit_retry_interval() {
    let response = Response::builder()
        .status(StatusCode::TOO_MANY_REQUESTS)
        .header(axum::http::header::RETRY_AFTER, "60")
        .body(Body::empty())
        .expect("rate-limited response");

    let response = RemoteHttpLimitRejection::with_retry_after(
        StatusCode::TOO_MANY_REQUESTS,
        "remote request concurrency limit reached",
    )
    .with_response_headers(response);

    assert_eq!(
        response.headers().get(axum::http::header::RETRY_AFTER),
        Some(&HeaderValue::from_static("60")),
    );
}

#[test]
fn remote_http_body_limit_uses_exact_route_contracts_and_operator_ceiling() {
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, SOURCE_BUNDLE_PATH),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, SOURCE_BUNDLE_RECEIPT_PATH),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, OFFER_PATH),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        OFFER_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, SOURCE_BUNDLE_ABANDON_PATH),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, HEARTBEAT_PATH),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, http_paths::POLICIES_IMPORT),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, http_paths::POLICIES_DUMP),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::GET, SOURCE_BUNDLE_PATH),
            MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
        ),
        DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES,
    );
    assert_eq!(
        effective_remote_http_body_limit(
            &body_limit_request(Method::POST, SOURCE_BUNDLE_PATH),
            512,
        ),
        512,
    );
}

#[test]
fn remote_request_limit_config_rejects_disabled_or_inconsistent_boundaries() {
    let disabled = RemoteRequestLimitConfig {
        max_http_concurrency: 0,
        ..RemoteRequestLimitConfig::default()
    };
    assert!(disabled.validate().is_err());

    let inconsistent = RemoteRequestLimitConfig {
        max_websocket_frame_bytes: 2,
        max_websocket_message_bytes: 1,
        ..RemoteRequestLimitConfig::default()
    };
    assert!(inconsistent.validate().is_err());
}

#[tokio::test]
async fn remote_http_admission_fails_closed_without_runtime_limits() {
    let mut state = crate::daemon::http::tests::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_request_limits = None;
    let (base_url, server) = serve_admission(
        state,
        Router::new().route(http_paths::HEALTH, get(StatusCode::OK)),
    )
    .await;

    let response = reqwest::get(format!("{base_url}{}", http_paths::HEALTH))
        .await
        .expect("request missing limits");
    let status = response.status();
    let body: Value = response.json().await.expect("limit error json");

    stop_server(server).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"]["code"], "REMOTE_AUDIT");
}

#[tokio::test]
async fn remote_http_admission_rejects_excess_concurrency() {
    let config = RemoteRequestLimitConfig {
        max_http_concurrency: 1,
        request_timeout: Duration::from_secs(5),
        ..RemoteRequestLimitConfig::default()
    };
    let state = remote_state(config);
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let app = Router::new()
        .route(http_paths::HEALTH, get(blocking_handler))
        .layer(Extension(BlockingRequest {
            started: Arc::clone(&started),
            release: Arc::clone(&release),
        }));
    let (base_url, server) = serve_admission(state, app).await;
    let request_url = format!("{base_url}{}", http_paths::HEALTH);
    let client = reqwest::Client::new();
    let first = tokio::spawn({
        let client = client.clone();
        let request_url = request_url.clone();
        async move { client.get(request_url).send().await }
    });
    started.notified().await;

    let overflow = client
        .get(&request_url)
        .send()
        .await
        .expect("overflow request");
    let overflow_status = overflow.status();
    let retry_after = overflow
        .headers()
        .get(axum::http::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);
    release.notify_waiters();
    let first_status = first
        .await
        .expect("join first request")
        .expect("first request")
        .status();

    stop_server(server).await;
    assert_eq!(overflow_status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(retry_after.as_deref(), Some("1"));
    assert_eq!(first_status, StatusCode::OK);
}

#[tokio::test]
async fn remote_http_admission_enforces_header_and_timeout_limits() {
    let header_config = RemoteRequestLimitConfig {
        max_http_header_bytes: 256,
        ..RemoteRequestLimitConfig::default()
    };
    let (base_url, server) = serve_admission(
        remote_state(header_config),
        Router::new().route(http_paths::HEALTH, get(StatusCode::OK)),
    )
    .await;
    let header_status = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-padding", "x".repeat(512))
        .send()
        .await
        .expect("oversized header request")
        .status();
    stop_server(server).await;

    let timeout_config = RemoteRequestLimitConfig {
        request_timeout: Duration::from_millis(20),
        ..RemoteRequestLimitConfig::default()
    };
    let (base_url, server) = serve_admission(
        remote_state(timeout_config),
        Router::new().route(http_paths::HEALTH, get(slow_handler)),
    )
    .await;
    let timeout_status = reqwest::get(format!("{base_url}{}", http_paths::HEALTH))
        .await
        .expect("timed request")
        .status();
    stop_server(server).await;

    assert_eq!(header_status, StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
    assert_eq!(timeout_status, StatusCode::GATEWAY_TIMEOUT);
}

#[tokio::test]
async fn local_http_requests_ignore_remote_body_limits() {
    let mut state = crate::daemon::http::tests::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Local;
    state.remote_request_limits = None;
    let app = Router::new()
        .route("/", get(StatusCode::OK))
        .layer(middleware::from_fn_with_state(
            state,
            limit_remote_http_body,
        ));
    let (base_url, server) = serve_router(app).await;

    let status = reqwest::Client::new()
        .get(base_url)
        .body(vec![
            b'x';
            DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES + 1
        ])
        .send()
        .await
        .expect("local oversized request")
        .status();

    stop_server(server).await;
    assert_eq!(status, StatusCode::OK);
}

#[derive(Clone)]
struct BlockingRequest {
    started: Arc<Notify>,
    release: Arc<Notify>,
}

async fn blocking_handler(Extension(blocking): Extension<BlockingRequest>) -> StatusCode {
    blocking.started.notify_one();
    blocking.release.notified().await;
    StatusCode::OK
}

async fn slow_handler() -> StatusCode {
    tokio::time::sleep(Duration::from_secs(1)).await;
    StatusCode::OK
}

fn body_limit_request(method: Method, path: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(path)
        .body(Body::empty())
        .expect("body limit request")
}

fn remote_state(config: RemoteRequestLimitConfig) -> DaemonHttpState {
    let mut state = crate::daemon::http::tests::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_request_limits = Some(RemoteRequestLimits::new(config).expect("valid limits"));
    state
}

async fn serve_admission(
    state: DaemonHttpState,
    app: Router,
) -> (String, tokio::task::JoinHandle<()>) {
    serve_router(app.layer(middleware::from_fn_with_state(
        state,
        admit_remote_http_request,
    )))
    .await
}

async fn serve_router(app: Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind request limit test listener");
    let address = listener.local_addr().expect("request limit address");
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve request limit test router");
    });
    (format!("http://{address}"), server)
}

async fn stop_server(server: tokio::task::JoinHandle<()>) {
    server.abort();
    let _ = server.await;
}
