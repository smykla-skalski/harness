use std::time::Duration;

use axum::http::{HeaderValue, header::AUTHORIZATION};
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteRole;
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::RemoteClientRegistration;

pub(super) fn register_remote_client(
    state: &crate::daemon::http::DaemonHttpState,
    client_id: &str,
    role: RemoteRole,
) {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "Remote viewer test client",
        "test",
        role,
        crate::daemon::remote::scopes_for_role(role),
        &remote_token(client_id),
        "2026-07-13T00:00:00Z",
    )
    .expect("remote registration");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .register_remote_client(&registration)
        .expect("register remote client");
}

pub(super) async fn get_http_json(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    client_id: &str,
) -> Value {
    let response = client
        .get(format!("{base_url}{path}"))
        .header(REMOTE_CLIENT_ID_HEADER, client_id)
        .bearer_auth(remote_token(client_id))
        .send()
        .await
        .expect("send remote viewer request");
    let status = response.status();
    let body = response.json::<Value>().await.expect("remote viewer json");
    assert_eq!(status, StatusCode::OK, "remote viewer response: {body}");
    body
}

pub(super) async fn connect_remote_ws(
    base_url: &str,
    client_id: &str,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let mut request = format!(
        "{}{}",
        base_url.replacen("http://", "ws://", 1),
        http_paths::WS
    )
    .into_client_request()
    .expect("websocket request");
    request.headers_mut().insert(
        REMOTE_CLIENT_ID_HEADER,
        HeaderValue::from_str(client_id).expect("client id header"),
    );
    request.headers_mut().insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {}", remote_token(client_id)))
            .expect("authorization header"),
    );
    connect_async(request).await.expect("connect websocket").0
}

pub(super) async fn ws_rpc<S>(socket: &mut S, id: &str, method: &str, params: Value) -> Value
where
    S: SinkExt<Message>
        + StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
        + Unpin,
    <S as futures_util::Sink<Message>>::Error: std::fmt::Debug,
{
    timeout(Duration::from_secs(5), async {
        socket
            .send(Message::Text(
                json!({ "id": id, "method": method, "params": params })
                    .to_string()
                    .into(),
            ))
            .await
            .expect("send websocket request");
        while let Some(frame) = socket.next().await {
            let Message::Text(text) = frame.expect("read websocket frame") else {
                continue;
            };
            let value = serde_json::from_str::<Value>(&text).expect("websocket json");
            if value["id"].as_str() == Some(id) {
                return value;
            }
        }
        panic!("missing websocket response for {id}");
    })
    .await
    .expect("websocket response timeout")
}

fn remote_token(client_id: &str) -> String {
    format!("remote-token-secret-{client_id}")
}

pub(super) async fn serve_http(
    state: crate::daemon::http::DaemonHttpState,
) -> (String, JoinHandle<()>) {
    let app = super::super::daemon_http_router(state);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let address = listener.local_addr().expect("listener address");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{address}"), server)
}
