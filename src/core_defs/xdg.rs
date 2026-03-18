use std::env;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::errors::CliError;

use super::paths::{dirs_home, harness_data_root};

/// XDG data root (`XDG_DATA_HOME` or `~/.local/share`).
#[must_use]
pub fn data_root() -> PathBuf {
    if let Ok(xdg) = env::var("XDG_DATA_HOME")
        && !xdg.is_empty()
    {
        return PathBuf::from(xdg);
    }
    dirs_home().join(".local").join("share")
}

/// Suite root: `harness_data_root/suites`.
#[must_use]
pub fn suite_root() -> PathBuf {
    harness_data_root().join("suites")
}

/// Read an env var, returning `None` if empty, an unexpanded shell variable,
/// or a known sentinel value like "UNSET".
fn context_scope_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("${") && trimmed.ends_with('}') {
        return None;
    }
    if trimmed.eq_ignore_ascii_case("unset") {
        return None;
    }
    Some(trimmed.to_string())
}

/// Compute a hex digest prefix from a scope string.
fn scope_digest(scope: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    let hash = hasher.finalize();
    hex_encode_prefix(&hash, 8)
}

/// Encode the first `n` bytes of a hash as lowercase hex (producing `2*n` chars).
fn hex_encode_prefix(bytes: &[u8], n: usize) -> String {
    bytes
        .iter()
        .take(n)
        .fold(String::with_capacity(n * 2), |mut acc, b| {
            use std::fmt::Write;
            let _ = write!(acc, "{b:02x}");
            acc
        })
}

/// Compute a context scope key from environment (session > project > cwd).
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn session_scope_key() -> Result<String, CliError> {
    if let Some(session_id) = context_scope_value("CLAUDE_SESSION_ID") {
        let scope = format!("session:{session_id}");
        return Ok(format!("session-{}", scope_digest(&scope)));
    }
    if let Some(project_dir) = context_scope_value("CLAUDE_PROJECT_DIR") {
        let resolved = PathBuf::from(project_dir).canonicalize()?;
        let scope = format!("project:{}", resolved.display());
        return Ok(format!("project-{}", scope_digest(&scope)));
    }
    let cwd = env::current_dir()?;
    let resolved = cwd.canonicalize().unwrap_or(cwd);
    let scope = format!("cwd:{}", resolved.display());
    Ok(format!("cwd-{}", scope_digest(&scope)))
}

/// Session context directory.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn session_context_dir() -> Result<PathBuf, CliError> {
    Ok(harness_data_root()
        .join("contexts")
        .join(session_scope_key()?))
}

/// Path to the current run context JSON file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn current_run_context_path() -> Result<PathBuf, CliError> {
    Ok(session_context_dir()?.join("current-run.json"))
}

/// Project context directory (hashed from project path).
#[must_use]
pub fn project_context_dir(project_dir: &Path) -> PathBuf {
    let resolved = project_dir
        .canonicalize()
        .unwrap_or_else(|_| project_dir.to_path_buf());
    let scope = resolved.to_string_lossy();
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    let hash = hasher.finalize();
    let digest = hex_encode_prefix(&hash, 8);
    harness_data_root()
        .join("projects")
        .join(format!("project-{digest}"))
}
