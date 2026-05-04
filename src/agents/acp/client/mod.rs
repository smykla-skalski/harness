//! ACP Client implementation for harness.
//!
//! Harness acts as the ACP *client* (IDE/host side): it spawns agents, sends
//! prompts, and handles `fs/*`, `terminal/*`, `session/request_permission`
//! requests. This module implements the handler logic for each request type,
//! enforcing write-surface policy, denied-binary checks, and permission gates.
//!
//! # Rejection-Recovery Contract (inline)
//!
//! Every denial is a structured JSON-RPC error with a code from the constants
//! below and a human-readable message. Agents SHOULD surface the message to
//! the user and SHOULD NOT retry the same operation without user intervention.
//!
//! Rejection scenarios covered by the recovery contract:
//!
//! - **Denied write**: agent asks to write outside the run surface or to a
//!   control file -> error `WRITE_DENIED` with path and reason. Agent shows
//!   the denial, does not retry, proceeds with the turn or asks for guidance.
//!
//! - **Denied binary**: agent asks to create/overwrite a managed cluster
//!   binary -> error `BINARY_DENIED` with binary name. Same recovery.
//!
//! - **Terminal denied**: agent asks to spawn a denied binary in a terminal ->
//!   error `TERMINAL_DENIED` with command. Same recovery.
//!
//! - **Permission rejected**: user denies a `request_permission` -> the
//!   response carries `RequestPermissionOutcome::Selected` with the reject
//!   option id. Agent must treat this as a soft denial and surface it to
//!   the user.
//!
//! - **Permission cancelled**: turn cancelled mid-permission-request -> the
//!   response carries `RequestPermissionOutcome::Cancelled`. Agent stops
//!   the turn.

mod permission_gate;
mod terminal;

use std::collections::BTreeSet;
use std::error::Error;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_client_protocol::schema::{
    CreateTerminalRequest, CreateTerminalResponse, KillTerminalRequest, KillTerminalResponse,
    ReadTextFileRequest, ReadTextFileResponse, ReleaseTerminalRequest, ReleaseTerminalResponse,
    RequestPermissionRequest, RequestPermissionResponse, TerminalId, TerminalOutputRequest,
    TerminalOutputResponse, WaitForTerminalExitRequest, WaitForTerminalExitResponse,
    WriteTextFileRequest, WriteTextFileResponse,
};
use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::oneshot;
use tokio::task::block_in_place;
use tokio::time::timeout;

use crate::agents::acp::supervision::MAX_TERMINALS_PER_SESSION;
use crate::agents::policy::{DeniedBinaries, WriteDecision, WriteSurfaceContext, evaluate_write};

use super::permission::{
    PermissionBridgeResult, PermissionMode, is_allow_outcome, record_terminal_decision,
    record_write_decision, recording_permission_gateway, stdin_permission_gateway,
};
use permission_gate::{terminal_permission_request, write_permission_request};
use terminal::TerminalManager;

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
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl Error for ClientError {}

/// ACP client handler state.
pub struct HarnessAcpClient {
    /// Working directory for file operations.
    working_dir: PathBuf,
    /// Run directory for write-surface evaluation.
    run_dir: PathBuf,
    /// Optional suite directory.
    suite_dir: Option<PathBuf>,
    /// Set of denied binary names.
    denied_binaries: DeniedBinaries,
    /// Permission mode for this session.
    permission_mode: PermissionMode,
    /// Terminal manager.
    terminals: TerminalManager,
}

impl HarnessAcpClient {
    /// Create a new client handler.
    #[must_use]
    pub fn new(
        working_dir: PathBuf,
        run_dir: PathBuf,
        suite_dir: Option<PathBuf>,
        denied_binaries: BTreeSet<String>,
        permission_mode: PermissionMode,
    ) -> Self {
        Self {
            working_dir,
            run_dir,
            suite_dir,
            denied_binaries: DeniedBinaries::new(denied_binaries),
            permission_mode,
            terminals: TerminalManager::new(MAX_TERMINALS_PER_SESSION),
        }
    }

    /// Handle `fs/read_text_file`.
    ///
    /// # Errors
    ///
    /// Returns `READ_DENIED` if the path escapes the working directory or the
    /// file cannot be read.
    pub fn handle_read_text_file(
        &self,
        request: &ReadTextFileRequest,
    ) -> ClientResult<ReadTextFileResponse> {
        let path = &request.path;

        if !is_path_within(&self.working_dir, path) {
            return Err(ClientError::read_denied(format!(
                "path '{}' escapes working directory",
                path.display()
            )));
        }

        let content = fs::read_to_string(path).map_err(|e| {
            ClientError::read_denied(format!("failed to read '{}': {e}", path.display()))
        })?;

        let content = if let (Some(line), Some(limit)) = (request.line, request.limit) {
            let start = (line.saturating_sub(1)) as usize;
            let limit = limit as usize;
            content
                .lines()
                .skip(start)
                .take(limit)
                .collect::<Vec<_>>()
                .join("\n")
        } else if let Some(line) = request.line {
            let start = (line.saturating_sub(1)) as usize;
            content.lines().skip(start).collect::<Vec<_>>().join("\n")
        } else if let Some(limit) = request.limit {
            content
                .lines()
                .take(limit as usize)
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            content
        };

        Ok(ReadTextFileResponse::new(content))
    }

    /// Handle `fs/write_text_file`.
    ///
    /// Rejection-recovery contract: a denied write is terminal for that tool
    /// call. The client returns a named JSON-RPC error (`WRITE_DENIED` for
    /// surface/control/symlink failures, `BINARY_DENIED` for managed-cluster
    /// binaries) with the rejected path and reason. The agent should surface
    /// that message, stop retrying the same write, and either continue the
    /// turn with the denied action omitted or ask the user for a different
    /// path/action.
    ///
    /// # Errors
    ///
    /// Returns `WRITE_DENIED` if the path escapes the run surface, targets a
    /// control file, or the file cannot be written. Returns `BINARY_DENIED` if
    /// the path would create a denied binary.
    pub fn handle_write_text_file(
        &self,
        request: &WriteTextFileRequest,
    ) -> ClientResult<WriteTextFileResponse> {
        let path = &request.path;
        let ctx = if let Some(ref suite_dir) = self.suite_dir {
            WriteSurfaceContext::new(&self.run_dir).with_suite_dir(suite_dir)
        } else {
            WriteSurfaceContext::new(&self.run_dir)
        };

        let decision = evaluate_write(path, &ctx, &self.denied_binaries);

        let policy_error = match decision {
            WriteDecision::Allow => None,
            WriteDecision::DenyControlFile { hint } => Some(ClientError::write_denied(format!(
                "cannot write to control file '{}': {hint}",
                path.display()
            ))),
            WriteDecision::DenyOutsideSurface => Some(ClientError::write_denied(format!(
                "path '{}' is outside the run surface",
                path.display()
            ))),
            WriteDecision::DenyTraversal => Some(ClientError::write_denied(format!(
                "path '{}' escapes via traversal",
                path.display()
            ))),
            WriteDecision::DenyBinary { name } => Some(ClientError::binary_denied(&name)),
            WriteDecision::DenySymlinkEscape { resolved } => {
                Some(ClientError::write_denied(format!(
                    "symlink '{}' escapes to '{}'",
                    path.display(),
                    resolved.display()
                )))
            }
            WriteDecision::DenyCheckFailed { reason } => Some(ClientError::write_denied(reason)),
        };
        if let Some(error) = policy_error {
            let result = Err(error);
            if let PermissionMode::Recording { log_path } = &self.permission_mode {
                record_write_decision(log_path, request, result.as_ref().map(|_| ()));
            }
            return result;
        }

        self.require_permission(&write_permission_request(request))
            .map_err(|error| {
                if error.is_permission_gateway_error() {
                    error
                } else {
                    ClientError::write_denied(error.message)
                }
            })?;

        let result = (|| {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(|e| {
                    ClientError::write_denied(format!(
                        "failed to create parent directory '{}': {e}",
                        parent.display()
                    ))
                })?;
            }

            fs::write(path, &request.content).map_err(|e| {
                ClientError::write_denied(format!("failed to write '{}': {e}", path.display()))
            })?;

            Ok(WriteTextFileResponse::new())
        })();
        if let PermissionMode::Recording { log_path } = &self.permission_mode {
            record_write_decision(log_path, request, result.as_ref().map(|_| ()));
        }
        result
    }

    /// Handle `terminal/create`.
    ///
    /// Rejection-recovery contract: a denied terminal spawn is terminal for
    /// that tool call. The client returns `TERMINAL_DENIED` for denied
    /// commands, terminal-cap exhaustion, PTY allocation failure, or spawn
    /// failure. The agent should surface the command and reason, stop retrying
    /// the same terminal command without changed user intent, and continue the
    /// turn with non-terminal alternatives where possible.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_DENIED` if the command is a denied binary, the cap is
    /// reached, or the process fails to spawn.
    pub fn handle_create_terminal(
        &self,
        request: &CreateTerminalRequest,
    ) -> ClientResult<CreateTerminalResponse> {
        let validation = self
            .terminals
            .validate_create_request(request, &self.denied_binaries);
        if let Err(error) = validation {
            if let PermissionMode::Recording { log_path } = &self.permission_mode {
                record_terminal_decision(log_path, request, Err(&error));
            }
            return Err(error);
        }
        self.require_permission(&terminal_permission_request(request))
            .map_err(|error| {
                if error.is_permission_gateway_error() {
                    error
                } else {
                    ClientError::terminal_denied(error.message)
                }
            })?;
        let result = self.terminals.handle_create(request, &self.denied_binaries);
        if let PermissionMode::Recording { log_path } = &self.permission_mode {
            record_terminal_decision(log_path, request, result.as_ref().map(|_| ()));
        }
        result
    }

    /// Handle `terminal/output`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown.
    pub fn handle_terminal_output(
        &self,
        request: &TerminalOutputRequest,
    ) -> ClientResult<TerminalOutputResponse> {
        self.terminals.handle_output(request)
    }

    /// Handle `terminal/wait_for_exit`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown, or
    /// `TERMINAL_DENIED` if the wait fails.
    pub fn handle_wait_for_terminal_exit(
        &self,
        request: &WaitForTerminalExitRequest,
    ) -> ClientResult<WaitForTerminalExitResponse> {
        self.terminals.handle_wait_for_exit(request)
    }

    /// Handle `terminal/kill`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown.
    pub fn handle_kill_terminal(
        &self,
        request: &KillTerminalRequest,
    ) -> ClientResult<KillTerminalResponse> {
        self.terminals.handle_kill(request)
    }

    /// Handle `terminal/release`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown.
    pub fn handle_release_terminal(
        &self,
        request: &ReleaseTerminalRequest,
    ) -> ClientResult<ReleaseTerminalResponse> {
        self.terminals.handle_release(request)
    }

    /// Handle `session/request_permission`.
    ///
    /// # Errors
    ///
    /// Returns `PERMISSION_TIMEOUT` if the stdin gateway fails or if the daemon
    /// bridge response deadline expires. Returns `DAEMON_SHUTDOWN` if the
    /// daemon bridge is gone.
    pub fn handle_request_permission(
        &self,
        request: &RequestPermissionRequest,
    ) -> ClientResult<RequestPermissionResponse> {
        match &self.permission_mode {
            PermissionMode::Stdin => stdin_permission_gateway(request).map_err(|e| {
                ClientError::new(PERMISSION_TIMEOUT, format!("stdin permission failed: {e}"))
            }),
            PermissionMode::Recording { log_path } => {
                recording_permission_gateway(log_path, request).map_err(|e| {
                    ClientError::new(PERMISSION_TIMEOUT, format!("record permission failed: {e}"))
                })
            }
            PermissionMode::DaemonBridge { tx, deadline } => {
                ensure_permission_bridge_wait_runtime_supported()?;
                let (response_tx, response_rx) = oneshot::channel();
                tx.try_send(super::permission::PermissionBridgeRequest {
                    request: request.clone(),
                    deadline: *deadline,
                    response_tx,
                })
                .map_err(|error| match error {
                    TrySendError::Full(_) => {
                        ClientError::new(PERMISSION_CAP_REACHED, "permission bridge queue is full")
                    }
                    TrySendError::Closed(_) => {
                        ClientError::new(DAEMON_SHUTDOWN, "permission bridge disconnected")
                    }
                })?;
                wait_permission_bridge_response(*deadline, response_rx)
            }
        }
    }

    pub(super) fn require_permission(
        &self,
        request: &RequestPermissionRequest,
    ) -> ClientResult<()> {
        if matches!(self.permission_mode, PermissionMode::Recording { .. }) {
            return Ok(());
        }

        let options = request.options.clone();
        let response = self.handle_request_permission(request)?;
        if is_allow_outcome(&response.outcome, &options) {
            Ok(())
        } else {
            Err(ClientError::new(
                WRITE_DENIED,
                "permission denied by user or cancelled",
            ))
        }
    }
}

impl ClientError {
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

fn ensure_permission_bridge_wait_runtime_supported() -> ClientResult<()> {
    let Ok(current) = Handle::try_current() else {
        return Ok(());
    };
    if matches!(current.runtime_flavor(), RuntimeFlavor::CurrentThread) {
        return Err(ClientError::new(
            PERMISSION_RUNTIME_UNSUPPORTED,
            "daemon bridge permission waits must run on a blocking thread outside tokio current-thread runtimes",
        ));
    }
    Ok(())
}

// Raw synchronous waits are supported outside Tokio and on Tokio multi-thread
// runtimes. Current-thread runtimes must move the whole client call to
// spawn_blocking so the bridge worker is never starved by the waiter.
fn wait_permission_bridge_response(
    deadline: Duration,
    response_rx: oneshot::Receiver<PermissionBridgeResult>,
) -> ClientResult<RequestPermissionResponse> {
    let future = async move {
        match timeout(deadline, response_rx).await {
            Ok(Ok(Ok(response))) => Ok(response),
            Ok(Ok(Err(error))) => Err(ClientError::new(error.code, error.message)),
            Ok(Err(_)) => Err(ClientError::new(
                DAEMON_SHUTDOWN,
                "permission bridge disconnected",
            )),
            Err(_) => Err(ClientError::new(
                PERMISSION_TIMEOUT,
                "permission response timed out",
            )),
        }
    };

    match Handle::try_current() {
        Ok(current) => match current.runtime_flavor() {
            RuntimeFlavor::MultiThread => block_in_place(|| current.block_on(future)),
            RuntimeFlavor::CurrentThread => Err(ClientError::new(
                PERMISSION_RUNTIME_UNSUPPORTED,
                "daemon bridge permission waits must run on a blocking thread outside tokio current-thread runtimes",
            )),
            _ => current.block_on(future),
        },
        Err(_) => Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| {
                ClientError::new(
                    PERMISSION_TIMEOUT,
                    format!("build permission wait runtime: {error}"),
                )
            })?
            .block_on(future),
    }
}

/// Check if a path is within a directory.
fn is_path_within(base: &Path, path: &Path) -> bool {
    let Ok(canonical_base) = base.canonicalize() else {
        return false;
    };
    let Ok(canonical_path) = path.canonicalize() else {
        if let Some(parent) = path.parent()
            && let Ok(canonical_parent) = parent.canonicalize()
        {
            return canonical_parent.starts_with(&canonical_base);
        }
        return false;
    };
    canonical_path.starts_with(&canonical_base)
}

#[cfg(test)]
mod tests;
