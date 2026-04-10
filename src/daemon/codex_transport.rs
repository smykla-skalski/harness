use std::env;
use std::pin::Pin;
use std::process::Stdio;

use async_trait::async_trait;
use futures_util::sink::SinkExt;
use futures_util::stream::StreamExt;
#[cfg(test)]
use tokio::io::DuplexStream;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio_tungstenite::tungstenite::Error as WsError;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, Message, frame::coding::CloseCode};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

use crate::errors::{CliError, CliErrorKind};

/// Async frame-oriented transport carrying newline-delimited JSON-RPC between
/// the daemon and a Codex `app-server`. Implementations hide whether the far
/// side is a child process (stdio) or a WebSocket connection.
#[async_trait]
pub trait CodexTransport: Send {
    /// Send a JSON-RPC message to the Codex peer. Implementations must append
    /// any framing (newline, WS text frame) required by the underlying
    /// transport before flushing.
    async fn send(&mut self, frame: String) -> Result<(), CliError>;

    /// Read the next JSON-RPC message from the Codex peer. `Ok(None)` means
    /// the far side closed the stream cleanly; `Err` is only returned when
    /// the read itself failed.
    async fn next_frame(&mut self) -> Result<Option<String>, CliError>;

    /// Gracefully drain the transport and release the underlying resource.
    async fn shutdown(self: Box<Self>) -> Result<(), CliError>;
}

type BoxedWriter = Pin<Box<dyn AsyncWrite + Send + Unpin>>;
type BoxedReader = Pin<Box<dyn AsyncBufRead + Send + Unpin>>;

/// Stdio transport that speaks newline-delimited JSON-RPC with a local
/// `codex app-server --listen stdio://` child process. Owns the child handle
/// so dropping the transport terminates the server.
pub struct StdioCodexTransport {
    child: Option<Child>,
    writer: BoxedWriter,
    reader: BoxedReader,
}

impl StdioCodexTransport {
    /// Spawn a `codex app-server` subprocess over stdio.
    ///
    /// Respects `HARNESS_CODEX_BIN` for the executable path and falls back to
    /// `codex` on `PATH`. The child's stderr is drained into the daemon's
    /// tracing output at `debug` level.
    ///
    /// # Errors
    ///
    /// Returns a workflow I/O error when the child fails to spawn or its
    /// stdio handles cannot be captured.
    pub fn spawn() -> Result<Self, CliError> {
        let bin = env::var("HARNESS_CODEX_BIN").unwrap_or_else(|_| "codex".to_string());
        let mut child = Command::new(bin)
            .arg("app-server")
            .arg("--listen")
            .arg("stdio://")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("spawn codex app-server: {error}"))
            })?;

        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                loop {
                    match lines.next_line().await {
                        Ok(Some(line)) => tracing::debug!(line, "codex app-server stderr"),
                        Ok(None) => break,
                        Err(error) => {
                            tracing::warn!(%error, "failed to read codex app-server stderr");
                            break;
                        }
                    }
                }
            });
        }

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| CliErrorKind::workflow_io("codex app-server stdin unavailable"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| CliErrorKind::workflow_io("codex app-server stdout unavailable"))?;

        Ok(Self {
            child: Some(child),
            writer: Box::pin(stdin),
            reader: Box::pin(BufReader::new(stdout)),
        })
    }

    /// Build a stdio transport from in-memory duplex streams. Used by tests
    /// to avoid spawning a real `codex` binary; there is no owning child so
    /// `shutdown` only closes the writer.
    #[cfg(test)]
    fn from_duplex(writer: DuplexStream, reader: DuplexStream) -> Self {
        Self {
            child: None,
            writer: Box::pin(writer),
            reader: Box::pin(BufReader::new(reader)),
        }
    }
}

#[async_trait]
impl CodexTransport for StdioCodexTransport {
    async fn send(&mut self, frame: String) -> Result<(), CliError> {
        self.writer
            .write_all(frame.as_bytes())
            .await
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("write codex app-server stdin: {error}"))
            })?;
        self.writer.write_all(b"\n").await.map_err(|error| {
            CliErrorKind::workflow_io(format!("write codex app-server newline: {error}"))
        })?;
        self.writer.flush().await.map_err(|error| {
            CliErrorKind::workflow_io(format!("flush codex app-server stdin: {error}"))
        })?;
        Ok(())
    }

    async fn next_frame(&mut self) -> Result<Option<String>, CliError> {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).await.map_err(|error| {
            CliErrorKind::workflow_io(format!("read codex app-server stdout: {error}"))
        })?;
        if read == 0 {
            return Ok(None);
        }
        if line.ends_with('\n') {
            line.pop();
            if line.ends_with('\r') {
                line.pop();
            }
        }
        Ok(Some(line))
    }

    async fn shutdown(mut self: Box<Self>) -> Result<(), CliError> {
        let _ = self.writer.shutdown().await;
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
        }
        Ok(())
    }
}

impl Drop for StdioCodexTransport {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn connect_error(endpoint: &str, error: &WsError) -> CliError {
    tracing::warn!(%error, endpoint, "codex websocket connect failed");
    CliErrorKind::workflow_io(format!(
        "connect codex app-server over websocket at {endpoint}: {error}"
    ))
    .into()
}

/// WebSocket transport that speaks newline-delimited JSON-RPC with a remote
/// `codex app-server --listen ws://...` process. One JSON-RPC message per
/// text frame.
pub struct WebSocketCodexTransport {
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
    endpoint: String,
}

impl WebSocketCodexTransport {
    /// Connect to a Codex `app-server` exposed over WebSocket.
    ///
    /// # Errors
    ///
    /// Returns a workflow I/O error when the TCP or WebSocket handshake
    /// fails so the caller can surface the endpoint to operators.
    pub async fn connect(endpoint: impl Into<String>) -> Result<Self, CliError> {
        let endpoint = endpoint.into();
        let result = connect_async(&endpoint).await;
        let (socket, _response) = result.map_err(|error| connect_error(&endpoint, &error))?;
        Ok(Self { socket, endpoint })
    }

    /// Endpoint URL the transport is bound to.
    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }
}

#[async_trait]
impl CodexTransport for WebSocketCodexTransport {
    async fn send(&mut self, frame: String) -> Result<(), CliError> {
        self.socket
            .send(Message::Text(frame.into()))
            .await
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("send codex websocket frame: {error}")).into()
            })
    }

    async fn next_frame(&mut self) -> Result<Option<String>, CliError> {
        while let Some(message) = self.socket.next().await {
            let message = message.map_err(|error| {
                CliErrorKind::workflow_io(format!("read codex websocket frame: {error}"))
            })?;
            match message {
                Message::Text(text) => return Ok(Some(text.to_string())),
                Message::Binary(bytes) => {
                    let text = String::from_utf8(bytes.to_vec()).map_err(|error| {
                        CliErrorKind::workflow_parse(format!(
                            "decode codex websocket binary frame: {error}"
                        ))
                    })?;
                    return Ok(Some(text));
                }
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
                Message::Close(_) => return Ok(None),
            }
        }
        Ok(None)
    }

    async fn shutdown(mut self: Box<Self>) -> Result<(), CliError> {
        let _ = self
            .socket
            .send(Message::Close(Some(CloseFrame {
                code: CloseCode::Normal,
                reason: "harness daemon shutdown".into(),
            })))
            .await;
        let _ = self.socket.close(None).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{CodexTransport, StdioCodexTransport, WebSocketCodexTransport};
    use futures_util::sink::SinkExt;
    use futures_util::stream::StreamExt;
    use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;
    use tokio_tungstenite::tungstenite::protocol::Message;

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
        let result = WebSocketCodexTransport::connect("ws://127.0.0.1:1").await;
        assert!(result.is_err(), "connect must fail on closed port");
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
}
