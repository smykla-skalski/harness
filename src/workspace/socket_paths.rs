//! Short, flat unix-socket path namespace keyed by session id.
//!
//! # Migration scope (Task 11 audit)
//!
//! Every non-test `UnixListener::bind` / `UnixStream::connect` call in this
//! codebase receives a path that is already computed elsewhere:
//!
//! - `src/daemon/bridge/runtime.rs` — path comes from `ResolvedBridgeConfig::socket_path`,
//!   which is built in `bridge_state::bridge_socket_path_for_root`. The bridge is a
//!   single daemon-global socket with no session concept; its own path-budget logic
//!   (fallback to group container or `/tmp` hash) is intentional and unaffected.
//! - `src/daemon/bridge/client.rs` — path is loaded from persisted `BridgeState::socket_path`.
//! - `src/mcp/registry/client.rs` — path comes from `path::default_socket_path()`,
//!   which returns `<group>/mcp.sock` (the Monitor accessibility socket). No session
//!   concept; that socket is a shared singleton.
//!
//! No production call site constructs a socket path inline. The migration applied
//! in Task 11 is therefore limited to two test fixture helpers:
//!
//! - `src/mcp/registry/tests.rs` — `socket_path()` now calls `session_socket(dir.path(), "testid00", "registry")`
//! - `src/mcp/tools/tests.rs`    — same helper updated
//!
//! The bridge test files (`tests/cleanup_and_config.rs`, `tests/legacy_server.rs`) bind
//! to hardcoded names under the daemon root deliberately — they test legacy cleanup
//! behavior that depends on specific filenames and are not socket-path construction
//! tests; those are left unchanged.

use std::path::{Path, PathBuf};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum SocketPathError {
    #[error("socket purpose must be non-empty without '/': {0:?}")]
    InvalidPurpose(String),
}

/// # Errors
/// Returns `SocketPathError::InvalidPurpose` when the purpose is empty or
/// contains `'/'`.
pub fn validate_purpose(purpose: &str) -> Result<(), SocketPathError> {
    if purpose.is_empty() || purpose.contains('/') {
        return Err(SocketPathError::InvalidPurpose(purpose.to_string()));
    }
    Ok(())
}

/// Returns the flat `<root>/<session_id>-<purpose>.sock` path.
///
/// The path must fit within the `sun_path` budget (104 bytes on macOS/Linux).
/// The module test `path_fits_sun_path_limit_with_long_home` is the early
/// guardrail the design doc calls for: if a new purpose would breach the
/// budget on the synthetic long-home fixture, the test fails and either the
/// purpose must be shortened or the socket root relocated.
#[must_use]
pub fn session_socket(root: &Path, session_id: &str, purpose: &str) -> PathBuf {
    root.join(format!("{session_id}-{purpose}.sock"))
}

/// Preferred socket root given the data root. On macOS, places sockets at the
/// group-container root's sibling `sock/` (one level up from the harness data
/// root) to save bytes. Elsewhere, puts them under `<data-root>/sock/`.
#[must_use]
pub fn socket_root(data_root: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    if let Some(parent) = data_root.parent() {
        return parent.join("sock");
    }
    data_root.join("sock")
}

#[cfg(test)]
mod tests;
