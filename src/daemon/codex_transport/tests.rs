use std::collections::BTreeMap;

use futures_util::sink::SinkExt;
use futures_util::stream::StreamExt;
use tempfile::tempdir;
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::daemon::bridge::{BridgeState, acquire_bridge_lock_exclusive, bridge_state_path};
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::infra::io::write_json_pretty;

use super::*;

fn with_isolated_env<F: FnOnce()>(f: F) {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", None),
            ("XDG_DATA_HOME", None),
        ],
        f,
    );
}

fn write_bridge_state_for_test(endpoint: &str) {
    write_json_pretty(
        &bridge_state_path(),
        &BridgeState {
            socket_path: "/tmp/bridge.sock".to_string(),
            pid: std::process::id(),
            started_at: "2026-04-10T00:00:00Z".to_string(),
            token_path: "/tmp/auth-token".to_string(),
            capabilities: BTreeMap::from([(
                "codex".to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "websocket".to_string(),
                    endpoint: Some(endpoint.to_string()),
                    metadata: BTreeMap::from([("port".to_string(), "4500".to_string())]),
                },
            )]),
        },
    )
    .expect("write bridge state");
}

#[test]
fn codex_transport_from_env_defaults_stdio_when_unsandboxed() {
    with_isolated_env(|| {
        assert_eq!(codex_transport_from_env(false), CodexTransportKind::Stdio);
    });
}

#[test]
fn codex_transport_from_env_defaults_websocket_when_sandboxed() {
    with_isolated_env(|| {
        assert_eq!(
            codex_transport_from_env(true),
            CodexTransportKind::WebSocket {
                endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
            },
        );
    });
}

#[test]
fn codex_transport_from_env_prefers_environment_override() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", Some("ws://127.0.0.1:7777")),
            ("XDG_DATA_HOME", None),
        ],
        || {
            write_bridge_state_for_test("ws://127.0.0.1:9999");

            assert_eq!(
                codex_transport_from_env(true),
                CodexTransportKind::WebSocket {
                    endpoint: "ws://127.0.0.1:7777".to_string(),
                },
            );
        },
    );
}

#[test]
fn codex_transport_from_env_uses_bridge_state_when_no_override() {
    with_isolated_env(|| {
        write_bridge_state_for_test("ws://127.0.0.1:4501");
        let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");

        assert_eq!(
            codex_transport_from_env(false),
            CodexTransportKind::WebSocket {
                endpoint: "ws://127.0.0.1:4501".to_string(),
            },
        );
    });
}

#[test]
fn codex_transport_from_env_rejects_nonlocal_override_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", Some("ws://10.0.0.5:7000")),
            ("XDG_DATA_HOME", None),
        ],
        || {
            assert_eq!(
                codex_transport_from_env(true),
                CodexTransportKind::WebSocket {
                    endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
                },
            );
        },
    );
}

#[test]
fn codex_transport_from_env_rejects_nonlocal_bridge_state_when_sandboxed() {
    with_isolated_env(|| {
        write_bridge_state_for_test("ws://10.0.0.5:7000");
        let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");

        assert_eq!(
            codex_transport_from_env(true),
            CodexTransportKind::WebSocket {
                endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
            },
        );
    });
}

#[test]
fn codex_transport_from_env_bridge_state_unblocks_unsandboxed_ws() {
    with_isolated_env(|| {
        write_bridge_state_for_test("ws://127.0.0.1:4500");
        let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");

        assert_eq!(
            codex_transport_from_env(false),
            CodexTransportKind::WebSocket {
                endpoint: "ws://127.0.0.1:4500".to_string(),
            },
        );
    });
}

#[tokio::test]
async fn stdio_transport_send_and_receive_roundtrip() {
    let (client_writer, mut server_reader) = io::duplex(1024);
    let (mut server_writer, client_reader) = io::duplex(1024);
    let mut transport = StdioCodexTransport::from_duplex(client_writer, client_reader);

    transport
        .send(r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.to_string())
        .await
        .expect("send");

    let mut reader = BufReader::new(&mut server_reader);
    let mut line = String::new();
    reader.read_line(&mut line).await.expect("read");
    assert_eq!(
        line.trim_end(),
        r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    );

    server_writer
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"pong\"}\n")
        .await
        .expect("server write");
    server_writer.flush().await.expect("server flush");

    let frame = transport
        .next_frame()
        .await
        .expect("next_frame")
        .expect("some frame");
    assert_eq!(frame, r#"{"jsonrpc":"2.0","id":1,"result":"pong"}"#);

    drop(server_writer);
    let closed = transport.next_frame().await.expect("next_frame eof");
    assert!(closed.is_none());

    Box::new(transport).shutdown().await.expect("shutdown");
}

#[tokio::test]
async fn websocket_transport_connect_fails_without_server() {
    let error = WebSocketCodexTransport::connect("ws://127.0.0.1:1")
        .await
        .err()
        .expect("connect must fail on closed port");
    assert_eq!(error.code(), "CODEX001");
}

#[tokio::test]
async fn codex_transport_kind_websocket_connect_surfaces_codex001() {
    let kind = CodexTransportKind::WebSocket {
        endpoint: "ws://127.0.0.1:1".to_string(),
    };
    let error = kind
        .connect()
        .await
        .err()
        .expect("connect must fail on closed port");
    assert_eq!(error.code(), "CODEX001");
}

#[tokio::test]
async fn websocket_transport_roundtrip_against_echo_server() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let endpoint = format!("ws://127.0.0.1:{port}");

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let mut ws = accept_async(stream).await.expect("ws accept");
        while let Some(msg) = ws.next().await {
            match msg {
                Ok(Message::Text(text)) => {
                    if text == "stop" {
                        break;
                    }
                    ws.send(Message::Text(text)).await.expect("echo");
                }
                Ok(Message::Close(_)) | Err(_) => break,
                _ => {}
            }
        }
    });

    let mut transport = WebSocketCodexTransport::connect(endpoint.clone())
        .await
        .expect("connect");
    assert_eq!(transport.endpoint(), endpoint);

    transport
        .send(r#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.to_string())
        .await
        .expect("send");
    let frame = transport
        .next_frame()
        .await
        .expect("next_frame")
        .expect("echo frame");
    assert_eq!(frame, r#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#);

    transport.send("stop".to_string()).await.expect("stop send");
    Box::new(transport).shutdown().await.expect("shutdown");
    server.await.expect("server task");
}
