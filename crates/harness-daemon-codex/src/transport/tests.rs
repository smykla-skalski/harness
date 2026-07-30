use futures_util::sink::SinkExt;
use futures_util::stream::StreamExt;
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::protocol::Message;

use super::*;

#[test]
fn stdio_child_path_prefers_the_running_harness_binary_directory() {
    let expected = std::env::current_exe()
        .expect("current executable")
        .parent()
        .expect("executable directory")
        .to_path_buf();
    let path = stdio_child_path().expect("stdio child path");
    assert_eq!(std::env::split_paths(&path).next(), Some(expected));
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
