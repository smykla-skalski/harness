use std::env;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::errors::CliError;

use super::canonical_checkout_root;
#[cfg(target_os = "macos")]
use super::paths::host_home_dir;
use super::paths::{dirs_home, harness_data_root, normalized_env_value};

/// XDG data root (`XDG_DATA_HOME` or `~/.local/share`).
#[must_use]
pub fn data_root() -> PathBuf {
    if let Some(value) = normalized_env_value("XDG_DATA_HOME") {
        return PathBuf::from(value);
    }
    #[cfg(target_os = "macos")]
    if let Some(group_id) = normalized_env_value("HARNESS_APP_GROUP_ID") {
        let group_root = host_home_dir()
            .join("Library")
            .join("Group Containers")
            .join(&group_id);
        if group_root.exists() {
            return group_root;
        }
        // Legacy fallback: pre-migration Application Support path.
        return host_home_dir().join("Library").join("Application Support");
    }
    user_dirs::data_dir().unwrap_or_else(|_| dirs_home().join(".local").join("share"))
}

/// Suite root: `harness_data_root/suites`.
#[must_use]
pub fn suite_root() -> PathBuf {
    harness_data_root().join("suites")
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

fn project_scope_key_for(project_dir: &Path) -> String {
    let resolved = canonical_checkout_root(project_dir);
    let scope = format!("project:{}", resolved.display());
    format!("project-{}", scope_digest(&scope))
}

/// Compute a context scope key from environment (session > project > cwd).
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn session_scope_key() -> Result<String, CliError> {
    if let Some(session_id) = normalized_env_value("CLAUDE_SESSION_ID") {
        let scope = format!("session:{session_id}");
        return Ok(format!("session-{}", scope_digest(&scope)));
    }
    if let Some(project_dir) = normalized_env_value("CLAUDE_PROJECT_DIR") {
        return Ok(project_scope_key_for(Path::new(&project_dir)));
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

/// Session context directory for an explicit project path.
#[must_use]
pub fn session_context_dir_for_project(project_dir: &Path) -> PathBuf {
    harness_data_root()
        .join("contexts")
        .join(project_scope_key_for(project_dir))
}

/// Path to the current run context JSON file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn current_run_context_path() -> Result<PathBuf, CliError> {
    Ok(session_context_dir()?.join("current-run.json"))
}

/// Path to the current run context JSON file for an explicit project path.
#[must_use]
pub fn current_run_context_path_for_project(project_dir: &Path) -> PathBuf {
    session_context_dir_for_project(project_dir).join("current-run.json")
}

/// Project context directory (hashed from project path).
///
/// If the input path is already under `harness_data_root()/projects/project-{hex16}`,
/// it is returned as-is (idempotent). This allows storage functions to accept
/// a `context_root` directly when the original project path is unavailable.
#[must_use]
pub fn project_context_dir(project_dir: &Path) -> PathBuf {
    if let Some(existing) = as_existing_context_root(project_dir) {
        return existing;
    }
    let resolved = canonical_checkout_root(project_dir);
    let scope = resolved.to_string_lossy();
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    let hash = hasher.finalize();
    let digest = hex_encode_prefix(&hash, 8);
    harness_data_root()
        .join("projects")
        .join(format!("project-{digest}"))
}

/// Stable project context directory name for a project path.
#[must_use]
pub fn project_context_id(project_dir: &Path) -> Option<String> {
    project_context_dir(project_dir)
        .file_name()
        .and_then(|name| name.to_str())
        .map(ToString::to_string)
}

/// Check whether a path is already a context root (or a subdirectory of one)
/// under `harness_data_root()/projects/project-{hex16}`.
///
/// Returns the non-canonicalized form (`harness_data_root()/projects/{name}`)
/// so the result is consistent with the normal hashing path.
fn as_existing_context_root(path: &Path) -> Option<PathBuf> {
    let projects_dir = harness_data_root().join("projects");
    // Canonicalize both sides so symlinks (e.g. /var -> /private/var on macOS)
    // don't break prefix matching.
    let canonical_projects = projects_dir
        .canonicalize()
        .unwrap_or_else(|_| projects_dir.clone());
    let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let suffix = resolved.strip_prefix(&canonical_projects).ok()?;
    let first_component = suffix.components().next()?;
    let dir_name = first_component.as_os_str().to_str()?;
    if is_project_context_dir_name(dir_name) {
        // Return using the non-canonicalized prefix for consistency with the
        // normal hashing path which also uses harness_data_root() directly.
        return Some(projects_dir.join(dir_name));
    }
    None
}

/// Returns `true` if the name matches `project-{16 hex chars}`.
fn is_project_context_dir_name(name: &str) -> bool {
    let Some(hex_part) = name.strip_prefix("project-") else {
        return false;
    };
    hex_part.len() == 16 && hex_part.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
#[path = "session/tests.rs"]
mod tests;
