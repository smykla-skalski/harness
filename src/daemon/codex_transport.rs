use std::env;
use std::pin::Pin;
use std::process::Stdio;

use async_trait::async_trait;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};

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
    fn from_duplex(writer: tokio::io::DuplexStream, reader: tokio::io::DuplexStream) -> Self {
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

#[cfg(test)]
mod tests {
    use super::{CodexTransport, StdioCodexTransport};
    use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};

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
}
