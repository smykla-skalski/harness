use axum::http::{HeaderValue, StatusCode, header::AUTHORIZATION};
use futures_util::{SinkExt as _, Stream, StreamExt as _};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};

use crate::daemon::http::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::test_http_state_with_db;

const MAX_REMOTE_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_REMOTE_WEBSOCKET_CONNECTIONS: usize = 64;

#[tokio::test]
async fn remote_http_rejects_bodies_over_the_configured_limit() {
    let (base_url, server) = serve_remote(remote_state_with_viewer()).await;
    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .body(vec![b'x'; MAX_REMOTE_REQUEST_BYTES + 1])
        .send()
        .await
        .expect("send oversized remote request");
    let status = response.status();

    stop_server(server).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn remote_websocket_rejects_messages_over_the_configured_limit() {
    let (base_url, server) = serve_remote(remote_state_with_viewer()).await;
    let request = remote_ws_request(&base_url, "viewer", "ws-size-handshake");
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");
    let oversized = serde_json::json!({
        "id": "oversized-ws-request",
        "method": ws_methods::PING,
        "params": { "padding": "x".repeat(MAX_REMOTE_REQUEST_BYTES) },
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

fn remote_state_with_viewer() -> DaemonHttpState {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_domain = Some("daemon.example.com".to_string());
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

fn remote_token(client_id: &str) -> String {
    format!("token-{client_id}-abcdefghijklmnopqrstuvwxyz0123456789")
}

fn remote_ws_request(base_url: &str, client_id: &str, request_id: &str) -> axum::http::Request<()> {
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

async fn serve_remote(state: DaemonHttpState) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind remote test listener");
    let addr = listener.local_addr().expect("listener address");
    let app = super::super::daemon_http_router(state)
        .into_make_service_with_connect_info::<crate::daemon::http::DaemonConnectInfo>();
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve remote router");
    });
    (format!("http://{addr}"), server)
}

async fn stop_server(server: JoinHandle<()>) {
    server.abort();
    let _ = server.await;
}
