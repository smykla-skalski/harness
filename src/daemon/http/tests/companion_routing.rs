//! Behaviour of the companion routing seam on a live remote-mode router.
//!
//! These drive the real `daemon_http_router`, so they prove the layering that
//! makes companion traffic unauthenticated while the daemon's own API keeps
//! demanding credentials on the very same listener.

use axum::extract::Request;
use axum::http::{HeaderMap, StatusCode, Uri};
use axum::routing::any;
use axum::{Json, Router};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::http::{CompanionRouteConfig, CompanionRouter, DaemonHttpState};
use crate::daemon::protocol::http_paths;

use super::remote_limits_support::{remote_state_with_viewer, serve_remote};

const COMPANION_PREFIX: &str = "/panel";

/// What the companion saw: the request line and the headers the assertions care
/// about, echoed back as JSON so the test reads them from the daemon's answer.
async fn echo_request(uri: Uri, headers: HeaderMap, request: Request) -> Json<Value> {
    let _ = request;
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
        "path_and_query": uri.path_and_query().map(ToString::to_string),
        "headers": Value::Object(observed),
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
    let config =
        CompanionRouteConfig::new(upstream, COMPANION_PREFIX).expect("valid companion config");
    state.companion = Some(CompanionRouter::new(config));
    state
}

fn header(body: &Value, name: &str) -> Option<String> {
    body.get("headers")?
        .get(name)?
        .as_str()
        .map(ToOwned::to_owned)
}

#[tokio::test(flavor = "multi_thread")]
async fn companion_traffic_is_forwarded_verbatim_without_daemon_credentials() {
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
async fn hop_by_hop_headers_do_not_cross_the_proxy() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/"))
        .header("connection", "x-custom-hop")
        .header("x-custom-hop", "secret")
        .header("x-kept", "1")
        .send()
        .await
        .expect("companion request");

    let body: Value = response.json().await.expect("companion echo body");
    assert!(header(&body, "x-custom-hop").is_none());
    assert!(header(&body, "connection").is_none());
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
