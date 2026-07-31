//! End-to-end coverage for the daemon's `task_board_updated` live push.
//!
//! A real daemon spawned by `spawn_daemon_serve` owns every layer the push
//! crosses: the HTTP mutation path that bumps `change_tracking`, the watch
//! loop that polls it, the broadcast fan-out, and the per-connection relay
//! that filters by `global_subscription`. A WebSocket subscriber that has
//! called `stream.subscribe` receives a push whose payload carries the
//! revision and scopes produced by the watch loop, proving the whole chain
//! stays wired. A regression in any layer - a missing `bump_change_in_tx`,
//! a watch loop that skips `emit_task_board_updated`, a relay filter that
//! drops `session_id: None` events - fails here.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::runtime::Runtime;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::Message;

use super::*;

/// How long to wait for the watch loop's 2 s poll interval to surface a
/// `task_board_updated` push after the HTTP mutation. The default poll is
/// 2 s, so 6 s covers one full tick plus transport and scheduling jitter
/// without treating a slow CI box as a flake.
const TASK_BOARD_PUSH_WAIT: Duration = Duration::from_secs(6);

#[test]
fn task_board_update_emits_live_push_to_global_subscriber() {
    // The test runs on a regular thread so the helpers (`wait_for_daemon_ready`
    // et al.) that internally spin up their own `Runtime::new().block_on`
    // work as they do for the other integration tests. The WebSocket and
    // HTTP work is async, so it runs on a dedicated runtime created here
    // and torn down at the end of the test body.
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let runtime = Runtime::new().expect("test runtime");
    runtime.block_on(async {
        // Create an item over HTTP before the WS subscription is opened. The
        // watch loop will poll the resulting change-tracking row on its next
        // tick; without a subscription the relay drops the push. Opening
        // the subscriber immediately afterward, then asserting on the
        // second mutation's push, keeps the test from racing the subscribe
        // RPC's daemon-side commit against the watch loop's poll cadence.
        let create_status = http_post(
            &endpoint,
            &token,
            "/v1/task-board/items",
            &json!({ "id": "ws-push-item", "title": "live push probe", "status": "inbox" }),
        )
        .await;
        assert_eq!(create_status, 200, "create item status");

        let mut socket = open_global_subscriber(&endpoint, &token).await;

        // The second HTTP update (the path the CLI's `task item update` drives)
        // bumps `change_tracking` again and produces a new push with a higher
        // revision. The create-before-subscribe ordering above is
        // intentionally not asserted because the watch loop's poll deadline
        // could fire while this test's subscribe RPC is still in flight and
        // the relay would have to drop its push. Once the subscription is
        // confirmed live, this second mutation is the one whose push the
        // test proves.
        let update_status = http_put(
            &endpoint,
            &token,
            "/v1/task-board/items/ws-push-item",
            &json!({ "status": "todo" }),
        )
        .await;
        assert_eq!(update_status, 200, "update item status");

        let push = next_task_board_updated(&mut socket, TASK_BOARD_PUSH_WAIT)
            .await
            .expect("expected a task_board_updated push after an item update while subscribed");
        let revision = push_revision(&push);
        assert!(
            revision > 0,
            "revision must advance after a mutation, got {revision}"
        );
        assert!(
            push_scopes_contain(&push, "task_board:items"),
            "update must bump the items scope, got {:?}",
            push_scopes(&push)
        );

        let _ = socket.close(None).await;
    });
    drop(runtime);

    let stop_output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop failed: {}",
        output_text(&stop_output)
    );
    wait_for_child_exit(&mut daemon);
}

type SubscriberStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Drive the WebSocket upgrade, drop the initial `config` push, and send
/// `stream.subscribe` so the relay routes `session_id: None` events
/// (`task_board_updated`, `sessions_updated`) to this connection.
async fn open_global_subscriber(endpoint: &str, token: &str) -> SubscriberStream {
    let ws_url = format!(
        "{}{}",
        endpoint
            .replacen("http://", "ws://", 1)
            .replacen("https://", "wss://", 1),
        "/v1/ws"
    );
    let mut request = ws_url.into_client_request().expect("ws request");
    let authorization = format!("Bearer {token}");
    request.headers_mut().insert(
        "authorization",
        HeaderValue::from_str(&authorization).unwrap(),
    );

    let (mut socket, _) = connect_async(request).await.expect("connect websocket");
    drain_until_event(&mut socket, "config", Duration::from_secs(2))
        .await
        .expect("expected initial config push");

    let request_id = "subscribe-global";
    socket
        .send(Message::Text(
            json!({
                "id": request_id,
                "method": "stream.subscribe",
                "params": { "scope": "global" },
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("send stream.subscribe");

    drain_until_response(&mut socket, request_id, Duration::from_secs(2))
        .await
        .expect("expected stream.subscribe response");

    socket
}

/// Wait for the next `task_board_updated` push, dropping other global events
/// (`sessions_updated`, `sessions_updated_delta`) that the watch loop can
/// emit alongside it. The assertion targets `task_board_updated` specifically
/// because that is the live-update signal this test exists to pin.
async fn next_task_board_updated(
    socket: &mut SubscriberStream,
    deadline_wait: Duration,
) -> Option<Value> {
    let deadline = Instant::now() + deadline_wait;
    loop {
        let frame = next_frame(socket, deadline).await?;
        let text = frame.into_text().expect("text frame");
        let value: Value = serde_json::from_str(&text).expect("ws json");
        if value.get("event").and_then(Value::as_str) == Some("task_board_updated") {
            return Some(value);
        }
    }
}

async fn drain_until_event(
    socket: &mut SubscriberStream,
    event: &str,
    deadline_wait: Duration,
) -> Option<()> {
    let deadline = Instant::now() + deadline_wait;
    loop {
        let frame = next_frame(socket, deadline).await?;
        let text = frame.into_text().expect("text frame");
        let value: Value = serde_json::from_str(&text).expect("ws json");
        if value.get("event").and_then(Value::as_str) == Some(event) {
            return Some(());
        }
    }
}

async fn drain_until_response(
    socket: &mut SubscriberStream,
    request_id: &str,
    deadline_wait: Duration,
) -> Option<()> {
    let deadline = Instant::now() + deadline_wait;
    loop {
        let frame = next_frame(socket, deadline).await?;
        let text = frame.into_text().expect("text frame");
        let value: Value = serde_json::from_str(&text).expect("ws json");
        if value.get("id").and_then(Value::as_str) == Some(request_id) {
            return Some(());
        }
    }
}

/// Pull the next message, returning `None` on timeout or socket close so the
/// callers' `?` chains stay readable. A genuine socket error surfaces as a
/// panic with the underlying reason, since a silent `None` here would let a
/// broken connection masquerade as a missed push.
async fn next_frame(socket: &mut SubscriberStream, deadline: Instant) -> Option<Message> {
    match tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), socket.next()).await {
        Ok(Some(Ok(message))) => Some(message),
        Ok(Some(Err(error))) => panic!("websocket frame error: {error}"),
        Ok(None) => None,
        Err(_elapsed) => None,
    }
}

async fn http_post(endpoint: &str, token: &str, path: &str, body: &Value) -> u16 {
    http_request(reqwest::Method::POST, endpoint, token, path, Some(body)).await
}

async fn http_put(endpoint: &str, token: &str, path: &str, body: &Value) -> u16 {
    http_request(reqwest::Method::PUT, endpoint, token, path, Some(body)).await
}

async fn http_request(
    method: reqwest::Method,
    endpoint: &str,
    token: &str,
    path: &str,
    body: Option<&Value>,
) -> u16 {
    let url = format!(
        "{}/{}",
        endpoint.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let client = reqwest::Client::new();
    let mut request = client
        .request(method.clone(), &url)
        .bearer_auth(token)
        .timeout(Duration::from_secs(2));
    if let Some(body) = body {
        request = request.json(body);
    }
    let response = request
        .send()
        .await
        .unwrap_or_else(|error| panic!("{} {url}: {error}", method.as_str()));
    response.status().as_u16()
}

fn push_revision(push: &Value) -> u64 {
    push.get("payload")
        .and_then(|payload| payload.get("revision"))
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

fn push_scopes(push: &Value) -> Vec<String> {
    push.get("payload")
        .and_then(|payload| payload.get("scopes"))
        .and_then(Value::as_array)
        .map(|scopes| {
            scopes
                .iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn push_scopes_contain(push: &Value, scope: &str) -> bool {
    push_scopes(push).iter().any(|s| s == scope)
}
