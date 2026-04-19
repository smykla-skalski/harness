use axum::extract::{
    Path, State,
    ws::{Message, WebSocket, WebSocketUpgrade},
};
use axum::http::HeaderMap;
use axum::response::Response;
use std::time::Instant;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;
use tokio::sync::broadcast::error::RecvError;
use tokio::task::block_in_place;

use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::http::DaemonHttpState;
use crate::errors::{CliError, CliErrorKind};

use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};
use super::ensure_terminal_agent;

#[expect(clippy::too_many_lines, reason = "tokio select proxying loop")]
pub(super) async fn get_terminal_agent_attach(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    if let Err(error) = ensure_terminal_agent(&state, &agent_id) {
        return timed_json(
            "GET",
            "/v1/managed-agents/{id}/attach",
            &request_id,
            start,
            Err::<(), _>(error),
        );
    }

    if state.agent_tui_manager.state.sandboxed {
        let stream_result =
            block_in_place(|| BridgeClient::for_capability(BridgeCapability::AgentTui).and_then(
                |client| client.agent_tui_attach(&agent_id),
            ));

        let stream = match stream_result {
            Ok(stream) => stream,
            Err(error) => {
                return timed_json(
                    "GET",
                    "/v1/managed-agents/{id}/attach",
                    &request_id,
                    start,
                    Err::<(), _>(error),
                );
            }
        };

        if let Err(error) = stream.set_nonblocking(true) {
            return timed_json(
                "GET",
                "/v1/managed-agents/{id}/attach",
                &request_id,
                start,
                Err::<(), _>(CliError::from(CliErrorKind::workflow_io(error.to_string()))),
            );
        }

        let mut tokio_stream = match UnixStream::from_std(stream) {
            Ok(stream) => stream,
            Err(error) => {
                return timed_json(
                    "GET",
                    "/v1/managed-agents/{id}/attach",
                    &request_id,
                    start,
                    Err::<(), _>(CliError::from(CliErrorKind::workflow_io(error.to_string()))),
                );
            }
        };

        return ws.on_upgrade(move |mut socket: WebSocket| async move {
            let mut buf = [0u8; 4096];
            loop {
                tokio::select! {
                    msg = socket.recv() => {
                        if let Some(Ok(Message::Binary(bytes))) = msg {
                            if tokio_stream.write_all(&bytes).await.is_err() {
                                break;
                            }
                        } else if let Some(Ok(Message::Text(text))) = msg {
                            if tokio_stream.write_all(text.as_bytes()).await.is_err() {
                                break;
                            }
                        } else {
                            break;
                        }
                    }
                    res = tokio_stream.read(&mut buf) => {
                        match res {
                            Ok(0) | Err(_) => break,
                            Ok(count) => {
                                if socket.send(Message::Binary(buf[..count].to_vec().into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        });
    }

    let process = match state.agent_tui_manager.active_process(&agent_id) {
        Ok(process) => process,
        Err(error) => {
            return timed_json(
                "GET",
                "/v1/managed-agents/{id}/attach",
                &request_id,
                start,
                Err::<(), _>(error),
            );
        }
    };

    let attach_state = match process.attach_state() {
        Ok(attach_state) => attach_state,
        Err(error) => {
            return timed_json(
                "GET",
                "/v1/managed-agents/{id}/attach",
                &request_id,
                start,
                Err::<(), _>(error),
            );
        }
    };

    let initial_bytes = attach_state.initial_bytes;
    let rx = attach_state.broadcast_rx;
    ws.on_upgrade(move |mut socket: WebSocket| async move {
        let mut rx = rx;
        if !initial_bytes.is_empty()
            && socket
                .send(Message::Binary(initial_bytes.into()))
                .await
                .is_err()
        {
            return;
        }
        loop {
            tokio::select! {
                msg = socket.recv() => {
                    if let Some(Ok(Message::Binary(bytes))) = msg {
                        if process.write_bytes(&bytes).is_err() {
                            break;
                        }
                    } else if let Some(Ok(Message::Text(text))) = msg {
                        if process.write_bytes(text.as_bytes()).is_err() {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                res = rx.recv() => {
                    match res {
                        Ok(bytes) => {
                            let bytes: Vec<u8> = bytes;
                            if socket.send(Message::Binary(bytes.into())).await.is_err() {
                                break;
                            }
                        }
                        Err(RecvError::Lagged(_)) => {}
                        Err(RecvError::Closed) => break,
                    }
                }
            }
        }
    })
}
