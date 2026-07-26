//! Behaviour of the companion routing seam on a live remote-mode router.
//!
//! These drive the real `daemon_http_router`, so they prove the layering that
//! bypasses public daemon client auth for companion traffic, replaces it with
//! the private loopback credential, and keeps the daemon API authenticated.

use axum::http::StatusCode;
use serde_json::Value;
use tokio::time::{Duration, timeout};

use crate::daemon::protocol::http_paths;

use super::companion_routing_support::{
    COMPANION_TOKEN, closed_loopback_origin, header, spawn_body_stalled_companion_upstream,
    spawn_companion_upstream, spawn_stalled_companion_upstream, state_with_companion,
    state_with_companion_limits,
};
use super::remote_limits_support::{remote_state_with_viewer, send_remote_health, serve_remote};

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
