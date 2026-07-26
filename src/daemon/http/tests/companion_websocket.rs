//! The websocket half of the companion routing seam.
//!
//! The daemon is the only thing on the public origin, so a companion that wants
//! to push anything to a browser is reachable only through this relay. These
//! drive the real `daemon_http_router`, so they prove what a handshake carries
//! across the hop and what the daemon still declines to carry at all.

use axum::http::StatusCode;
use futures_util::StreamExt as _;
use serde_json::Value;
use tokio::time::{Duration, timeout};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use super::companion_routing_support::{
    COMPANION_TOKEN, spawn_companion_upstream, spawn_companion_websocket_upstream,
    state_with_companion,
};
use super::remote_limits_support::serve_remote;

/// The companion is the only thing that can push to a browser on this origin,
/// and the daemon is the only thing on it, so a handshake that stopped here
/// would leave the companion unable to say anything it was not asked.
#[tokio::test(flavor = "multi_thread")]
async fn a_websocket_under_the_prefix_reaches_the_companion() {
    let (upstream, upstream_server) = spawn_companion_websocket_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;
    let socket_url = format!("{}/panel/socket", base_url.replace("http://", "ws://"));

    let (mut socket, response) = connect_async(socket_url)
        .await
        .expect("the daemon must relay the handshake");

    assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
    // Bounded, because a relay that establishes the socket and then carries
    // nothing is exactly the regression this covers, and an unbounded read would
    // meet it by hanging the suite rather than by failing.
    let frame = timeout(Duration::from_secs(5), socket.next())
        .await
        .expect("the relayed socket must carry a frame rather than go silent");
    let Some(Ok(Message::Text(presented))) = frame else {
        panic!("the relayed socket must carry the companion's own frames");
    };
    assert_eq!(
        presented.as_str(),
        format!("Bearer {COMPANION_TOKEN}"),
        "the handshake must arrive wearing the daemon's companion credential"
    );

    server.abort();
    upstream_server.abort();
}

/// Websocket alone. Tunnelling a protocol the daemon cannot reason about would
/// turn a scoped companion prefix into a general way off the public listener.
#[tokio::test(flavor = "multi_thread")]
async fn no_other_protocol_upgrade_under_the_prefix_is_relayed() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    for upgrade in ["h2c", "TLS/1.2"] {
        let response = reqwest::Client::new()
            .get(format!("{base_url}/panel/socket"))
            .header("connection", "Upgrade")
            .header("upgrade", upgrade)
            .send()
            .await
            .expect("upgrade request");

        assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED, "{upgrade}");
        let body: Value = response.json().await.expect("error body");
        assert_eq!(body["error"]["code"].as_str(), Some("COMPANION_UPSTREAM"));
    }

    server.abort();
    upstream_server.abort();
}

/// A `GET` carrying only half a handshake is not one, and forwarding it would
/// make the companion refuse on the daemon's behalf.
#[tokio::test(flavor = "multi_thread")]
async fn half_a_handshake_under_the_prefix_is_refused() {
    let (upstream, upstream_server) = spawn_companion_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/socket"))
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

/// A companion that declines the handshake is answering the caller, not the
/// daemon, so its status, its headers, and its body all have to survive the hop.
/// A bare status would leave a browser with nothing to act on and would drop a
/// `WWW-Authenticate` that says what to do about it.
#[tokio::test(flavor = "multi_thread")]
async fn a_handshake_the_companion_declines_comes_back_whole() {
    let (upstream, upstream_server) = spawn_companion_websocket_upstream().await;
    let (base_url, server) = serve_remote(state_with_companion(&upstream)).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/panel/socket-refused"))
        .header("connection", "Upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-version", "13")
        .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        .send()
        .await
        .expect("upgrade request");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let challenge = response
        .headers()
        .get("www-authenticate")
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    assert_eq!(challenge.as_deref(), Some("Bearer"));
    let body: Value = response.json().await.expect("refusal body");
    assert_eq!(body["error"]["code"].as_str(), Some("unauthenticated"));

    server.abort();
    upstream_server.abort();
}
