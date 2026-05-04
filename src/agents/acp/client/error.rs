use std::error::Error;
use std::fmt;

use agent_client_protocol::schema::TerminalId;

/// JSON-RPC error code: write denied by policy.
pub const WRITE_DENIED: i32 = -32001;

/// JSON-RPC error code: denied binary.
pub const BINARY_DENIED: i32 = -32002;

/// JSON-RPC error code: terminal creation denied.
pub const TERMINAL_DENIED: i32 = -32003;

/// JSON-RPC error code: terminal not found.
pub const TERMINAL_NOT_FOUND: i32 = -32004;

/// JSON-RPC error code: read denied.
pub const READ_DENIED: i32 = -32005;

/// JSON-RPC error code: permission timeout.
pub const PERMISSION_TIMEOUT: i32 = -32006;

/// JSON-RPC error code: permission bridge concurrency cap reached.
pub const PERMISSION_CAP_REACHED: i32 = -32007;

/// JSON-RPC error code: permission wait requires a blocking thread.
pub const PERMISSION_RUNTIME_UNSUPPORTED: i32 = -32008;

/// JSON-RPC error code: daemon shutdown in progress.
pub const DAEMON_SHUTDOWN: i32 = -32099;

/// Result type for client handler operations.
pub type ClientResult<T> = Result<T, ClientError>;

/// Error returned by client handlers.
#[derive(Debug, Clone)]
pub struct ClientError {
    /// JSON-RPC error code.
    pub code: i32,
    /// Human-readable error message.
    pub message: String,
}

impl ClientError {
    #[must_use]
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    #[must_use]
    pub fn write_denied(reason: impl Into<String>) -> Self {
        Self::new(WRITE_DENIED, reason)
    }

    #[must_use]
    pub fn binary_denied(binary: &str) -> Self {
        Self::new(
            BINARY_DENIED,
            format!("denied binary '{binary}': use harness commands instead"),
        )
    }

    #[must_use]
    pub fn terminal_denied(reason: impl Into<String>) -> Self {
        Self::new(TERMINAL_DENIED, reason)
    }

    #[must_use]
    pub fn terminal_not_found(terminal_id: &TerminalId) -> Self {
        Self::new(
            TERMINAL_NOT_FOUND,
            format!("terminal '{terminal_id}' not found"),
        )
    }

    #[must_use]
    pub fn read_denied(reason: impl Into<String>) -> Self {
        Self::new(READ_DENIED, reason)
    }

    pub(super) fn is_permission_gateway_error(&self) -> bool {
        matches!(
            self.code,
            PERMISSION_TIMEOUT
                | DAEMON_SHUTDOWN
                | PERMISSION_CAP_REACHED
                | PERMISSION_RUNTIME_UNSUPPORTED
        )
    }
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl Error for ClientError {}
