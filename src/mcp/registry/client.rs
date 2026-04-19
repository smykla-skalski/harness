use std::fmt::Display;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::de::DeserializeOwned;
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{Mutex, MutexGuard};
use tokio::time::timeout;

use super::path::default_socket_path;
use super::types::{RegistryOutcome, RegistryRequest, RegistryResponse};

/// Default connect and request timeout for the accessibility registry.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
/// Default per-request timeout after the socket is connected.
pub const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Error)]
pub enum RegistryError {
    #[error(
        "Harness Monitor accessibility socket unavailable at {path}: {cause}. \
         Launch Harness Monitor.app and ensure the MCP listener task is running."
    )]
    Unavailable { path: PathBuf, cause: String },
    #[error("registry error ({code}): {message}")]
    Server { code: String, message: String },
    #[error("registry timeout: {detail}")]
    Timeout { detail: String },
    #[error("registry protocol error: {detail}")]
    Protocol { detail: String },
    #[error("registry closed: {detail}")]
    Closed { detail: String },
}

impl RegistryError {
    #[must_use]
    pub fn unavailable(path: &Path, cause: impl Display) -> Self {
        Self::Unavailable {
            path: path.to_path_buf(),
            cause: cause.to_string(),
        }
    }
}

/// Async client that speaks NDJSON over a Unix-domain socket with the
/// Harness Monitor accessibility registry. Each request carries a
/// monotonically increasing id; responses are matched by id.
///
/// The client connects lazily on the first request and reconnects on demand
/// if the socket closes. Only one in-flight request is permitted at a time;
/// callers that need concurrency should wrap in a pool.
pub struct RegistryClient {
    socket_path: PathBuf,
    connect_timeout: Duration,
    request_timeout: Duration,
    next_id: AtomicU64,
    connection: Mutex<Option<Connection>>,
}

struct Connection {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
}

impl RegistryClient {
    #[must_use]
    pub fn new() -> Self {
        Self::with_socket_path(default_socket_path())
    }

    #[must_use]
    pub fn with_socket_path(socket_path: PathBuf) -> Self {
        Self {
            socket_path,
            connect_timeout: DEFAULT_CONNECT_TIMEOUT,
            request_timeout: DEFAULT_REQUEST_TIMEOUT,
            next_id: AtomicU64::new(1),
            connection: Mutex::new(None),
        }
    }

    #[must_use]
    pub fn with_timeouts(mut self, connect: Duration, request: Duration) -> Self {
        self.connect_timeout = connect;
        self.request_timeout = request;
        self
    }

    /// Allocate the next request id. Exposed so callers building
    /// `RegistryRequest` variants have a consistent counter.
    pub fn next_request_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Send a single request and decode the typed result. The request id
    /// must match the one the caller allocated via `next_request_id`.
    ///
    /// # Errors
    /// Returns `RegistryError` on connection failures, timeouts, server
    /// errors, or result decoding failures.
    pub async fn request<T: DeserializeOwned>(
        &self,
        request: &RegistryRequest,
    ) -> Result<T, RegistryError> {
        let mut guard = self.connection.lock().await;
        let connection = self.ensure_connected(&mut guard).await?;
        let response = self.exchange(connection, request).await?;
        decode_outcome(response, request.id())
    }

    async fn ensure_connected<'a>(
        &self,
        guard: &'a mut MutexGuard<'_, Option<Connection>>,
    ) -> Result<&'a mut Connection, RegistryError> {
        if guard.is_none() {
            let connected = self.connect().await?;
            **guard = Some(connected);
        }
        Ok(guard.as_mut().expect("connection just set"))
    }

    async fn connect(&self) -> Result<Connection, RegistryError> {
        let stream = timeout(self.connect_timeout, UnixStream::connect(&self.socket_path))
            .await
            .map_err(|_| RegistryError::unavailable(&self.socket_path, "connect timeout"))?
            .map_err(|error| RegistryError::unavailable(&self.socket_path, error))?;
        let (read_half, write_half) = stream.into_split();
        Ok(Connection {
            reader: BufReader::new(read_half),
            writer: write_half,
        })
    }

    async fn exchange(
        &self,
        connection: &mut Connection,
        request: &RegistryRequest,
    ) -> Result<RegistryResponse, RegistryError> {
        let payload = serde_json::to_vec(request).map_err(|error| RegistryError::Protocol {
            detail: format!("encode request: {error}"),
        })?;
        write_line(&mut connection.writer, &payload).await?;
        read_response(&mut connection.reader, self.request_timeout).await
    }
}

impl Default for RegistryClient {
    fn default() -> Self {
        Self::new()
    }
}

async fn write_line(writer: &mut OwnedWriteHalf, payload: &[u8]) -> Result<(), RegistryError> {
    writer
        .write_all(payload)
        .await
        .map_err(|error| RegistryError::Closed {
            detail: format!("socket write: {error}"),
        })?;
    writer
        .write_all(b"\n")
        .await
        .map_err(|error| RegistryError::Closed {
            detail: format!("socket write newline: {error}"),
        })?;
    writer.flush().await.map_err(|error| RegistryError::Closed {
        detail: format!("socket flush: {error}"),
    })
}

async fn read_response(
    reader: &mut BufReader<OwnedReadHalf>,
    deadline: Duration,
) -> Result<RegistryResponse, RegistryError> {
    let mut line = String::new();
    let bytes = timeout(deadline, reader.read_line(&mut line))
        .await
        .map_err(|_| RegistryError::Timeout {
            detail: "response timeout".into(),
        })?
        .map_err(|error| RegistryError::Closed {
            detail: format!("socket read: {error}"),
        })?;
    if bytes == 0 {
        return Err(RegistryError::Closed {
            detail: "server closed connection".into(),
        });
    }
    serde_json::from_str(line.trim_end_matches(['\n', '\r'])).map_err(|error| {
        RegistryError::Protocol {
            detail: format!("decode response: {error}"),
        }
    })
}

fn decode_outcome<T: DeserializeOwned>(
    response: RegistryResponse,
    expected_id: u64,
) -> Result<T, RegistryError> {
    if response.id != expected_id {
        return Err(RegistryError::Protocol {
            detail: format!(
                "id mismatch: expected {expected_id}, got {actual}",
                actual = response.id,
            ),
        });
    }
    match response.outcome {
        RegistryOutcome::Ok { result, .. } => {
            serde_json::from_value(result).map_err(|error| RegistryError::Protocol {
                detail: format!("decode result: {error}"),
            })
        }
        RegistryOutcome::Err { error, .. } => Err(RegistryError::Server {
            code: error.code,
            message: error.message,
        }),
    }
}
