use async_trait::async_trait;
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader, duplex};

use crate::mcp::protocol::{
    ErrorCode, ErrorObject, Notification, Request, RequestId, Response,
};
use crate::mcp::server::{IncomingMessage, RequestHandler, serve};

#[test]
fn incoming_message_routes_requests_by_id_presence() {
    let req = IncomingMessage::parse(
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#,
    )
    .expect("parse request");
    match req {
        IncomingMessage::Request(r) => assert_eq!(r.method, "tools/list"),
        IncomingMessage::Notification(_) => panic!("expected request"),
    }

    let note = IncomingMessage::parse(
        r#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#,
    )
    .expect("parse notification");
    match note {
        IncomingMessage::Notification(n) => {
            assert_eq!(n.method, "notifications/initialized");
        }
        IncomingMessage::Request(_) => panic!("expected notification"),
    }
}

#[test]
fn incoming_message_rejects_invalid_json() {
    let err = IncomingMessage::parse("not json").expect_err("invalid json");
    assert!(err.to_string().to_lowercase().contains("expected"));
}

struct EchoHandler;

#[async_trait]
impl RequestHandler for EchoHandler {
    async fn handle_request(&self, request: Request) -> Response {
        match request.method.as_str() {
            "echo" => Response::success(request.id, request.params),
            _ => Response::error(
                request.id,
                ErrorObject::new(
                    ErrorCode::MethodNotFound,
                    format!("unknown method: {}", request.method),
                ),
            ),
        }
    }

    async fn handle_notification(&self, _notification: Notification) {}
}

#[tokio::test]
async fn serve_echoes_request_response_roundtrip() {
    let (mut client, server) = duplex(8192);
    let (server_read, mut server_write) = tokio::io::split(server);

    let handle = tokio::spawn(async move {
        let reader = BufReader::new(server_read);
        serve(reader, &mut server_write, EchoHandler).await
    });

    client
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\",\"params\":{\"hi\":1}}\n")
        .await
        .unwrap();
    client.shutdown().await.unwrap();

    let mut buf = String::new();
    client.read_to_string(&mut buf).await.unwrap();
    handle.await.unwrap().unwrap();

    let line = buf.lines().next().expect("one response line");
    let parsed: serde_json::Value = serde_json::from_str(line).unwrap();
    assert_eq!(parsed.get("id").unwrap(), &json!(1));
    assert_eq!(parsed.get("result").unwrap(), &json!({"hi": 1}));
}

#[tokio::test]
async fn serve_returns_parse_error_on_invalid_line() {
    let (mut client, server) = duplex(8192);
    let (server_read, mut server_write) = tokio::io::split(server);

    let handle = tokio::spawn(async move {
        let reader = BufReader::new(server_read);
        serve(reader, &mut server_write, EchoHandler).await
    });

    client.write_all(b"not-json\n").await.unwrap();
    client.shutdown().await.unwrap();

    let mut buf = String::new();
    client.read_to_string(&mut buf).await.unwrap();
    handle.await.unwrap().unwrap();

    let line = buf.lines().next().expect("parse error line");
    let parsed: serde_json::Value = serde_json::from_str(line).unwrap();
    let code = parsed
        .pointer("/error/code")
        .and_then(serde_json::Value::as_i64)
        .expect("error.code");
    assert_eq!(code, -32700);
}

#[tokio::test]
async fn serve_skips_blank_lines() {
    let (mut client, server) = duplex(8192);
    let (server_read, mut server_write) = tokio::io::split(server);

    let handle = tokio::spawn(async move {
        let reader = BufReader::new(server_read);
        serve(reader, &mut server_write, EchoHandler).await
    });

    client
        .write_all(b"\n\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"echo\",\"params\":null}\n")
        .await
        .unwrap();
    client.shutdown().await.unwrap();

    let mut buf = String::new();
    client.read_to_string(&mut buf).await.unwrap();
    handle.await.unwrap().unwrap();

    let lines: Vec<_> = buf.lines().collect();
    assert_eq!(lines.len(), 1, "blank lines should not produce output");
    let parsed: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(parsed.get("id").unwrap(), &json!(9));
}

#[tokio::test]
async fn serve_handles_notifications_without_response() {
    struct CountingHandler {
        tx: tokio::sync::mpsc::UnboundedSender<Notification>,
    }

    #[async_trait]
    impl RequestHandler for CountingHandler {
        async fn handle_request(&self, request: Request) -> Response {
            Response::error(
                request.id,
                ErrorObject::new(ErrorCode::MethodNotFound, "no requests here".into()),
            )
        }
        async fn handle_notification(&self, notification: Notification) {
            let _ = self.tx.send(notification);
        }
    }

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let (mut client, server) = duplex(4096);
    let (server_read, mut server_write) = tokio::io::split(server);

    let handle = tokio::spawn(async move {
        let reader = BufReader::new(server_read);
        serve(reader, &mut server_write, CountingHandler { tx }).await
    });

    client
        .write_all(
            b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}\n",
        )
        .await
        .unwrap();
    client.shutdown().await.unwrap();

    let mut buf = String::new();
    client.read_to_string(&mut buf).await.unwrap();
    handle.await.unwrap().unwrap();

    assert!(buf.is_empty(), "notifications emit no response, got {buf:?}");
    let note = rx.recv().await.expect("notification delivered");
    assert_eq!(note.method, "notifications/initialized");
}

#[test]
fn response_error_id_preserved() {
    let resp = Response::error(
        RequestId::String("x".into()),
        ErrorObject::new(ErrorCode::InvalidParams, "bad".into()),
    );
    let value = serde_json::to_value(&resp).unwrap();
    assert_eq!(value.get("id").unwrap(), "x");
}
