use std::io;
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};

use super::state;

pub const CODEX_BRIDGE_LAUNCH_AGENT_LABEL: &str = "io.harness.codex-bridge";
pub const DEFAULT_CODEX_BRIDGE_PORT: u16 = 4500;
pub const CODEX_BRIDGE_PORT_ENV: &str = "HARNESS_CODEX_WS_PORT";

/// Published endpoint state for a user-launched `codex app-server` supervised
/// by `harness codex-bridge`. The sandboxed daemon reads this file to discover
/// where Codex is listening so it can connect over WebSocket without spawning
/// a subprocess itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexBridgeState {
    /// Loopback WebSocket URL the codex app-server is listening on.
    pub endpoint: String,
    /// PID of the codex app-server child process.
    pub pid: u32,
    /// UTC timestamp when the bridge started supervising codex.
    pub started_at: String,
    /// Port the bridge chose, stored so `status` can confirm drift.
    pub port: u16,
    /// Codex version reported at startup, best-effort.
    #[serde(default)]
    pub codex_version: Option<String>,
}

#[must_use]
pub fn codex_endpoint_path() -> PathBuf {
    state::daemon_root().join("codex-endpoint.json")
}

#[must_use]
pub fn codex_bridge_pid_path() -> PathBuf {
    state::daemon_root().join("codex-bridge.pid")
}

/// Read the persisted bridge state, returning `None` when no bridge is
/// currently registered. Parse failures surface as `CliError` so corrupted
/// state files are loud rather than silently ignored.
///
/// # Errors
/// Returns a workflow parse error when the file exists but cannot be decoded.
pub fn read_bridge_state() -> Result<Option<CodexBridgeState>, CliError> {
    let path = codex_endpoint_path();
    if !path.is_file() {
        return Ok(None);
    }
    read_json_typed(&path).map(Some)
}

/// Atomically persist the bridge state to `codex-endpoint.json`, creating the
/// daemon directory tree on first use.
///
/// # Errors
/// Returns a workflow I/O error on directory or write failures.
pub fn write_bridge_state(state: &CodexBridgeState) -> Result<(), CliError> {
    super::state::ensure_daemon_dirs()?;
    write_json_pretty(&codex_endpoint_path(), state)
}

/// Persist the bridge PID alongside the endpoint file so `stop` can signal it
/// without parsing the JSON.
///
/// # Errors
/// Returns a workflow I/O error on write failure.
pub fn write_bridge_pid(pid: u32) -> Result<(), CliError> {
    super::state::ensure_daemon_dirs()?;
    write_text(&codex_bridge_pid_path(), &format!("{pid}\n"))
}

/// Load the persisted PID, returning `None` when the file is missing or
/// unparseable (treated as no running bridge).
#[must_use]
pub fn read_bridge_pid() -> Option<u32> {
    let path = codex_bridge_pid_path();
    let text = fs::read_to_string(&path).ok()?;
    text.trim().parse().ok()
}

/// Remove both the endpoint and PID files, ignoring missing entries so callers
/// can drive this from cleanup paths without pre-checking existence.
///
/// # Errors
/// Returns a workflow I/O error if a file exists but cannot be removed.
pub fn clear_bridge_state() -> Result<(), CliError> {
    remove_if_exists(&codex_endpoint_path())?;
    remove_if_exists(&codex_bridge_pid_path())?;
    Ok(())
}

fn remove_if_exists(path: &Path) -> Result<(), CliError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CliError::from(CliErrorKind::workflow_io(format!(
            "remove {}: {error}",
            path.display()
        )))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn sample_state() -> CodexBridgeState {
        CodexBridgeState {
            endpoint: "ws://127.0.0.1:4500".to_string(),
            pid: 12345,
            started_at: "2026-04-10T12:00:00Z".to_string(),
            port: 4500,
            codex_version: Some("0.102.0".to_string()),
        }
    }

    fn with_temp_daemon_root<F: FnOnce()>(f: F) {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", None),
            ],
            f,
        );
    }

    #[test]
    fn read_bridge_state_returns_none_when_missing() {
        with_temp_daemon_root(|| {
            assert!(read_bridge_state().expect("read").is_none());
        });
    }

    #[test]
    fn write_then_read_roundtrips_bridge_state() {
        with_temp_daemon_root(|| {
            let state = sample_state();
            write_bridge_state(&state).expect("write");
            let loaded = read_bridge_state().expect("read").expect("present");
            assert_eq!(loaded, state);
        });
    }

    #[test]
    fn write_bridge_pid_stores_trimmable_text() {
        with_temp_daemon_root(|| {
            write_bridge_pid(98765).expect("write pid");
            assert_eq!(read_bridge_pid(), Some(98765));
        });
    }

    #[test]
    fn clear_bridge_state_removes_both_files() {
        with_temp_daemon_root(|| {
            write_bridge_state(&sample_state()).expect("write state");
            write_bridge_pid(12345).expect("write pid");
            clear_bridge_state().expect("clear");
            assert!(!codex_endpoint_path().exists());
            assert!(!codex_bridge_pid_path().exists());
        });
    }

    #[test]
    fn clear_bridge_state_ignores_missing_files() {
        with_temp_daemon_root(|| {
            clear_bridge_state().expect("clear missing");
        });
    }
}
