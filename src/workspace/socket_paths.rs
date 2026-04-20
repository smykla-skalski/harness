//! Short, flat unix-socket path namespace keyed by session id.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use thiserror::Error;

/// Unix domain socket path limit on macOS and Linux.
const UNIX_SOCKET_PATH_LIMIT: usize = 104;

#[derive(Debug, Error)]
pub enum SocketPathError {
    #[error("socket purpose must be non-empty without '/': {0:?}")]
    InvalidPurpose(String),
}

/// # Errors
/// Returns `SocketPathError::InvalidPurpose` when the purpose is empty or contains '/'.
pub fn validate_purpose(purpose: &str) -> Result<(), SocketPathError> {
    if purpose.is_empty() || purpose.contains('/') {
        return Err(SocketPathError::InvalidPurpose(purpose.to_string()));
    }
    Ok(())
}

/// Returns a socket path under `root` for the given session and purpose.
///
/// When the human-readable name `{session_id}-{purpose}.sock` fits within the
/// unix socket path limit, it is used as-is. When the root directory is long
/// (e.g. on macOS with a group-container path) and the full path would exceed
/// the limit, a two-hex-char SHA-256 prefix of the pair is used instead so the
/// path always fits.
#[must_use]
pub fn session_socket(root: &Path, session_id: &str, purpose: &str) -> PathBuf {
    let full_name = format!("{session_id}-{purpose}.sock");
    let full_path = root.join(&full_name);
    if full_path.as_os_str().len() < UNIX_SOCKET_PATH_LIMIT {
        return full_path;
    }
    let mut hasher = Sha256::new();
    hasher.update(session_id.as_bytes());
    hasher.update(b"-");
    hasher.update(purpose.as_bytes());
    let hash = hasher.finalize();
    let short = hex::encode(&hash[..1]);
    root.join(format!("{short}.sock"))
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
