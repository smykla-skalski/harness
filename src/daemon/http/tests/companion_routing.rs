//! Behaviour of the companion routing seam on a live remote-mode router.
//!
//! These drive the real `daemon_http_router`, so they prove the layering that
//! bypasses public daemon client auth for companion traffic, replaces it with
//! the private loopback credential, and keeps the daemon API authenticated.

use std::convert::Infallible;
use std::future::pending;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::Request;
use axum::http::{HeaderMap, Response, StatusCode, Uri, Version, header::CONTENT_LENGTH};
use axum::routing::any;
use axum::{Json, Router};
use futures_util::{StreamExt as _, stream};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};

use crate::daemon::http::companion::CompanionAuthToken;
use crate::daemon::http::{
    CompanionRouteConfig, CompanionRouter, DaemonHttpState, RemoteRequestLimitConfig,
};
use crate::daemon::protocol::http_paths;

use super::remote_limits_support::{
    remote_state_with_viewer, remote_state_with_viewer_config, send_remote_health, serve_remote,
};

const COMPANION_PREFIX: &str = "/panel";
const COMPANION_TOKEN: &str = "daemon-panel-test-token-0123456789";

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

async fn spawn_companion_upstream() -> (String, JoinHandle<()>) {
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

/// A port nothing is listening on: bind, read the address, then drop the
/// listener so the connect attempt is refused rather than hanging.
async fn closed_loopback_origin() -> String {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind throwaway listener");
    let address = listener.local_addr().expect("throwaway address");
    drop(listener);
    format!("http://{address}")
}

fn state_with_companion(upstream: &str) -> DaemonHttpState {
    let mut state = remote_state_with_viewer();
    let token = CompanionAuthToken::parse(COMPANION_TOKEN).expect("valid companion token");
    let config = CompanionRouteConfig::new(upstream, COMPANION_PREFIX, token)
        .expect("valid companion config");
    state.companion = Some(CompanionRouter::new(config));
    state
}

fn state_with_companion_limits(
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

async fn spawn_stalled_companion_upstream() -> (String, Arc<Notify>, JoinHandle<()>) {
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

async fn spawn_body_stalled_companion_upstream() -> (String, JoinHandle<()>) {
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

fn header(body: &Value, name: &str) -> Option<String> {
    body.get("headers")?
        .get(name)?
        .as_str()
        .map(ToOwned::to_owned)
}

#[tokio::test(flavor = "multi_thread")]
async fn http2_companion_traffic_stays_http2_on_the_loopback_hop() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;
    let client = reqwest::Client::builder()
        .http2_prior_knowledge()
        .build()
        .expect("HTTP/2 client");

    let response = client
        .get(format!("{base_url}/panel/healthz"))
        .send()
        .await
        .expect("HTTP/2 companion request");

    assert_eq!(response.version(), reqwest::Version::HTTP_2);
    let body: Value = response.json().await.expect("companion echo body");
    assert_eq!(body["is_http2"], true);
    assert_eq!(body["is_http1"], false);
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn http1_companion_traffic_stays_http1_on_the_loopback_hop() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;
    let client = reqwest::Client::builder()
        .http1_only()
        .build()
        .expect("HTTP/1 client");

    let response = client
        .get(format!("{base_url}/panel/healthz"))
        .send()
        .await
        .expect("HTTP/1 companion request");

    assert_eq!(response.version(), reqwest::Version::HTTP_11);
    let body: Value = response.json().await.expect("companion echo body");
    assert_eq!(body["is_http1"], true);
    assert_eq!(body["is_http2"], false);
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn companion_traffic_is_forwarded_with_loopback_credentials() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/api/me?verbose=1"))
        .send()
        .await
        .expect("companion request");

    assert_eq!(response.status(), StatusCode::OK);
    let body: Value = response.json().await.expect("companion echo body");
    assert_eq!(
        body["path_and_query"].as_str(),
        Some("/panel/api/me?verbose=1"),
        "the prefix and query must reach the companion unchanged"
    );
    assert_eq!(
        header(&body, "authorization"),
        Some(format!("Bearer {COMPANION_TOKEN}"))
    );
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn forwarded_headers_describe_the_public_hop_and_replace_caller_values() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/"))
        .header("x-forwarded-for", "10.0.0.1")
        .header("x-forwarded-proto", "http")
        .header("x-forwarded-host", "spoofed.example")
        .send()
        .await
        .expect("companion request");

    let body: Value = response.json().await.expect("companion echo body");
    assert_eq!(
        header(&body, "x-forwarded-for").as_deref(),
        Some("127.0.0.1")
    );
    assert_eq!(header(&body, "x-forwarded-proto").as_deref(), Some("https"));
    assert_eq!(
        header(&body, "x-forwarded-host"),
        Some(base_url.replace("http://", "")),
        "the companion must see the origin the caller actually reached"
    );
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn caller_credentials_are_replaced_by_the_companion_credential() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/api/me"))
        .header("authorization", "Bearer daemon-token")
        .header("x-harness-remote-client-id", "viewer")
        .header("forwarded", "for=10.0.0.1;proto=http")
        .send()
        .await
        .expect("companion request");

    let body: Value = response.json().await.expect("companion echo body");
    assert_eq!(
        header(&body, "authorization"),
        Some(format!("Bearer {COMPANION_TOKEN}"))
    );
    assert_eq!(body["authorization_count"].as_u64(), Some(1));
    assert!(header(&body, "x-harness-remote-client-id").is_none());
    assert!(header(&body, "forwarded").is_none());
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn hop_by_hop_headers_do_not_cross_the_proxy() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/"))
        .header("connection", "x-custom-hop")
        .header("x-custom-hop", "secret")
        .header("proxy-connection", "keep-alive")
        .header("x-kept", "1")
        .send()
        .await
        .expect("companion request");

    let body: Value = response.json().await.expect("companion echo body");
    assert!(header(&body, "x-custom-hop").is_none());
    assert!(header(&body, "connection").is_none());
    assert!(header(&body, "proxy-connection").is_none());
    assert_eq!(header(&body, "x-kept").as_deref(), Some("1"));
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn daemon_routes_still_demand_credentials_while_a_companion_is_configured() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::READY))
        .send()
        .await
        .expect("daemon request");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn paths_outside_the_prefix_are_not_forwarded() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panelling"))
        .send()
        .await
        .expect("unmatched request");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn github_sign_in_starts_are_limited_without_blocking_other_companion_routes() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;
    let client = reqwest::Client::new();
    let start_url = format!("{base_url}/panel/auth/github/start");

    for attempt in 1..=4 {
        let response = client
            .get(&start_url)
            .send()
            .await
            .expect("GitHub sign-in start");
        assert_eq!(
            response.status(),
            StatusCode::OK,
            "attempt {attempt} should be admitted"
        );
    }

    let limited = client
        .get(&start_url)
        .send()
        .await
        .expect("rate-limited GitHub sign-in start");
    assert_eq!(limited.status(), StatusCode::TOO_MANY_REQUESTS);
    let retry_after = limited
        .headers()
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .expect("numeric Retry-After");
    assert!((1..=600).contains(&retry_after));
    let body: Value = limited.json().await.expect("rate-limit error body");
    assert_eq!(
        body["error"]["code"].as_str(),
        Some("COMPANION_OAUTH_START_RATE_LIMIT")
    );
    assert_eq!(
        body["error"]["message"].as_str(),
        Some("GitHub sign-in attempts are rate limited")
    );

    let non_state_method = client
        .post(&start_url)
        .send()
        .await
        .expect("non-state method");
    assert_eq!(non_state_method.status(), StatusCode::OK);

    let unaffected = client
        .get(format!("{base_url}/panel/api/me"))
        .send()
        .await
        .expect("unrelated companion route");
    assert_eq!(unaffected.status(), StatusCode::OK);
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn the_prefix_is_unrouted_when_no_companion_is_configured() {
    let (base_url, server) = serve_remote(remote_state_with_viewer()).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/api/me"))
        .send()
        .await
        .expect("unmatched request");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unreachable_companion_answers_bad_gateway() {
    let upstream = closed_loopback_origin().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/api/me"))
        .send()
        .await
        .expect("companion request");

    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    let body: Value = response.json().await.expect("error body");
    assert_eq!(body["error"]["code"].as_str(), Some("COMPANION_UPSTREAM"));
    server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stalled_companion_cannot_exhaust_the_core_api_request_lane() {
    let (upstream, started, upstream_server) = spawn_stalled_companion_upstream().await;
    let state = state_with_companion_limits(&upstream, 2, 1);
    let (base_url, server) = serve_remote(state).await;
    let client = reqwest::Client::new();
    let first_client = client.clone();
    let first_url = format!("{base_url}/panel/api/me");
    let first = tokio::spawn(async move { first_client.get(first_url).send().await });
    timeout(Duration::from_secs(2), started.notified())
        .await
        .expect("first companion request reached upstream");

    let overflow = client
        .get(format!("{base_url}/panel/api/me"))
        .send()
        .await
        .expect("overflow companion request");
    let core = send_remote_health(client, base_url, "companion-bulkhead-core-request")
        .await
        .expect("authenticated core request");

    assert_eq!(overflow.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(core.status(), StatusCode::OK);
    first.abort();
    server.abort();
    upstream_server.abort();
}

#[tokio::test]
async fn a_stalled_response_body_holds_the_bulkhead_until_its_timeout() {
    let (upstream, upstream_server) = spawn_body_stalled_companion_upstream().await;
    let state = state_with_companion_limits(&upstream, 1, 2);
    let (base_url, server) = serve_remote(state).await;
    let client = reqwest::Client::new();
    let first = client
        .get(format!("{base_url}/panel/api/me"))
        .send()
        .await
        .expect("first companion response headers");
    assert_eq!(first.status(), StatusCode::OK);

    let overflow = client
        .get(format!("{base_url}/panel/api/me"))
        .send()
        .await
        .expect("overflow companion request");
    assert_eq!(overflow.status(), StatusCode::TOO_MANY_REQUESTS);

    tokio::time::pause();
    let first_body = tokio::spawn(async move { first.bytes().await });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(61)).await;
    tokio::time::resume();
    let _body_error = timeout(Duration::from_secs(1), first_body)
        .await
        .expect("body timeout completed")
        .expect("body task")
        .expect_err("stalled body must fail");

    tokio::task::yield_now().await;
    let recovered = timeout(
        Duration::from_secs(1),
        client.get(format!("{base_url}/panel/api/me")).send(),
    )
    .await
    .expect("request after body timeout")
    .expect("recovered companion response");
    assert_eq!(recovered.status(), StatusCode::OK);
    server.abort();
    upstream_server.abort();
}

#[tokio::test(flavor = "multi_thread")]
async fn protocol_upgrades_under_the_prefix_are_refused() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/socket"))
        .header("connection", "Upgrade")
        .header("upgrade", "websocket")
        .send()
        .await
        .expect("upgrade request");

    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let body: Value = response.json().await.expect("error body");
    assert_eq!(body["error"]["code"].as_str(), Some("COMPANION_UPSTREAM"));
    server.abort();
    upstream_server.abort();
}
