use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::errors::CliError;

/// Build information resolved from the repo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildInfo {
    pub version: String,
}

impl BuildInfo {
    #[must_use]
    pub fn env(&self) -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("BUILD_INFO_VERSION".to_string(), self.version.clone());
        m
    }
}

/// Result of running an external command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub args: Vec<String>,
    pub returncode: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Return current UTC time as ISO 8601 with Z suffix and no microseconds.
#[must_use]
pub fn utc_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// XDG data root (XDG_DATA_HOME or ~/.local/share).
#[must_use]
pub fn data_root() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME")
        && !xdg.is_empty()
    {
        return PathBuf::from(xdg);
    }
    dirs_home().join(".local").join("share")
}

/// Harness data root: data_root/kuma.
#[must_use]
pub fn harness_data_root() -> PathBuf {
    data_root().join("kuma")
}

/// Suite root: harness_data_root/suites.
#[must_use]
pub fn suite_root() -> PathBuf {
    harness_data_root().join("suites")
}

/// Compute a context scope key from environment (session > project > cwd).
#[must_use]
pub fn session_scope_key() -> String {
    todo!()
}

/// Session context directory.
#[must_use]
pub fn session_context_dir() -> PathBuf {
    todo!()
}

/// Project context directory (hashed from project path).
#[must_use]
pub fn project_context_dir(_project_dir: &Path) -> PathBuf {
    todo!()
}

/// Merge current env with extra key-value pairs.
#[must_use]
pub fn merge_env(extra: Option<&HashMap<String, String>>) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = std::env::vars().collect();
    if let Some(extra) = extra {
        env.extend(extra.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    env
}

/// Resolve build info from a repo path.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn resolve_build_info(_repo: &Path) -> Result<BuildInfo, CliError> {
    todo!()
}

/// Render an error for display to stderr.
#[must_use]
pub fn render_error(error: &CliError) -> String {
    crate::errors::render_error(error)
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

#[cfg(test)]
mod tests {}
