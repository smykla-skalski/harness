//! Short, flat unix-socket path namespace keyed by session id.

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
