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

use super::bridge;

/// Default WebSocket endpoint for a user-launched Codex app-server when the
/// daemon runs under the macOS App Sandbox and cannot spawn child processes.
pub const DEFAULT_CODEX_WS_ENDPOINT: &str = "ws://127.0.0.1:4500";

/// How the daemon should reach its Codex app-server.
///
/// Stdio spawns a local `codex app-server` child process and talks over its
/// stdin/stdout. WebSocket connects to a user-launched `codex app-server
/// --listen ws://...` so that a sandboxed daemon can still drive Codex runs
/// without spawning subprocesses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexTransportKind {
    Stdio,
    WebSocket { endpoint: String },
}

impl CodexTransportKind {
    /// Short textual label written into the daemon manifest for observability.
    #[must_use]
    pub fn manifest_label(&self) -> &'static str {
        match self {
            Self::Stdio => "stdio",
            Self::WebSocket { .. } => "websocket",
        }
    }

    /// Endpoint URL for the WebSocket variant, or `None` for stdio.
    #[must_use]
    pub fn endpoint(&self) -> Option<&str> {
        match self {
            Self::Stdio => None,
            Self::WebSocket { endpoint } => Some(endpoint.as_str()),
        }
    }

    /// Construct a live transport that the Codex JSON-RPC state machine can
    /// drive. Stdio spawns a child process synchronously; the WebSocket
    /// variant performs an async TCP + WS handshake.
    ///
    /// # Errors
    ///
    /// Returns a workflow I/O error when the underlying transport fails to
    /// come up (child spawn, TCP connect, WS handshake).
    pub async fn connect(&self) -> Result<Box<dyn CodexTransport>, CliError> {
        match self {
            Self::Stdio => Ok(Box::new(StdioCodexTransport::spawn()?)),
            Self::WebSocket { endpoint } => {
                Ok(Box::new(WebSocketCodexTransport::connect(endpoint).await?))
            }
        }
    }
}

/// Resolve the transport kind for a given daemon sandbox mode, consulting
/// (in order) an explicit `HARNESS_CODEX_WS_URL`, the unified host bridge
/// state file, and finally the sandbox default.
///
/// * Sandboxed daemons always use WebSocket (they cannot spawn children).
///   The endpoint falls back to [`DEFAULT_CODEX_WS_ENDPOINT`] when nothing
///   else is published so the daemon still surfaces a structured
///   `codex-unavailable` error rather than silently degrading.
/// * Unsandboxed daemons default to stdio unless an operator has explicitly
///   opted into WebSocket via the env var or a running bridge.
#[must_use]
pub fn codex_transport_from_env(sandboxed: bool) -> CodexTransportKind {
    let override_url = env::var("HARNESS_CODEX_WS_URL")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    if let Some(endpoint) = override_url {
        return CodexTransportKind::WebSocket { endpoint };
    }

    if let Some(endpoint) = bridge_endpoint_from_state_file() {
        return CodexTransportKind::WebSocket { endpoint };
    }

    if sandboxed {
        return CodexTransportKind::WebSocket {
            endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
        };
    }

    CodexTransportKind::Stdio
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn bridge_endpoint_from_state_file() -> Option<String> {
    match bridge::codex_websocket_endpoint() {
        Ok(endpoint) => endpoint,
        Err(error) => {
            tracing::warn!(%error, "failed to read bridge state file; falling back to defaults");
            None
        }
    }
}

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
    CliErrorKind::codex_server_unavailable(endpoint.to_string()).into()
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
    use super::{
        CodexTransport, CodexTransportKind, DEFAULT_CODEX_WS_ENDPOINT, StdioCodexTransport,
        WebSocketCodexTransport, codex_transport_from_env,
    };
    use crate::daemon::bridge::{BridgeState, acquire_bridge_lock_exclusive, bridge_state_path};
    use crate::daemon::state::HostBridgeCapabilityManifest;
    use crate::infra::io::write_json_pretty;
    use futures_util::sink::SinkExt;
    use futures_util::stream::StreamExt;
    use std::collections::BTreeMap;
    use tempfile::tempdir;
    use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;
    use tokio_tungstenite::tungstenite::protocol::Message;

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
                // Publish a bridge state too; env override must still win.
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
            // Hold bridge.lock so LockOnly path sees the bridge as running.
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
    fn codex_transport_from_env_bridge_state_unblocks_unsandboxed_ws() {
        with_isolated_env(|| {
            write_bridge_state_for_test("ws://127.0.0.1:4500");
            // Hold bridge.lock so LockOnly path sees the bridge as running.
            let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");

            // Unsandboxed: normally defaults to stdio, but the presence of a
            // bridge state file means the operator has explicitly signed up
            // for websocket transport via `harness bridge start`.
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
        let kind = super::CodexTransportKind::WebSocket {
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
}
