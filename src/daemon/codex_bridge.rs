use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use fs_err as fs;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};

use super::codex_transport;
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

/// Debounce window for coalescing rapid `notify` events from atomic writes
/// (tmp-file rename produces several events back-to-back).
const WATCH_DEBOUNCE: Duration = Duration::from_millis(200);

/// Spawn a background task that watches the codex-bridge endpoint file and
/// republishes the daemon manifest's `codex_transport` / `codex_endpoint`
/// fields whenever a bridge starts, stops, or changes port.
///
/// The watcher re-resolves the transport via `codex_transport_from_env`, so
/// env overrides still win and stdio fallback still applies when no bridge
/// is running. Changes are written atomically via `state::write_manifest`,
/// which means Swift clients observing the manifest file pick them up
/// through their existing `ManifestWatcher`.
#[must_use]
pub fn spawn_bridge_endpoint_watcher(sandboxed: bool) -> JoinHandle<()> {
    tokio::spawn(async move {
        run_bridge_endpoint_watcher(sandboxed).await;
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn run_bridge_endpoint_watcher(sandboxed: bool) {
    let Some(daemon_root) = ensure_watcher_root() else {
        return;
    };
    let (event_tx, mut event_rx) = mpsc::channel::<notify::Result<notify::Event>>(32);
    let Some(_watcher) = build_endpoint_watcher(&daemon_root, event_tx) else {
        tracing::warn!("codex-bridge watcher: failed to build filesystem watcher");
        return;
    };

    apply_bridge_state_to_manifest(sandboxed);
    watch_endpoint_events(&mut event_rx, sandboxed).await;
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn ensure_watcher_root() -> Option<PathBuf> {
    match state::ensure_daemon_dirs() {
        Ok(()) => Some(state::daemon_root()),
        Err(error) => {
            tracing::warn!(%error, "codex-bridge watcher: unable to ensure daemon root");
            None
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn watch_endpoint_events(
    event_rx: &mut mpsc::Receiver<notify::Result<notify::Event>>,
    sandboxed: bool,
) {
    while event_rx.recv().await.is_some() {
        sleep(WATCH_DEBOUNCE).await;
        while event_rx.try_recv().is_ok() {}
        apply_bridge_state_to_manifest(sandboxed);
    }
    tracing::debug!("codex-bridge watcher: channel closed, exiting");
}

fn build_endpoint_watcher(
    daemon_root: &Path,
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> Option<RecommendedWatcher> {
    let mut watcher = RecommendedWatcher::new(
        move |result| {
            let _ = event_tx.blocking_send(result);
        },
        notify::Config::default(),
    )
    .ok()?;
    watcher
        .watch(daemon_root, RecursiveMode::NonRecursive)
        .ok()?;
    Some(watcher)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn apply_bridge_state_to_manifest(sandboxed: bool) {
    let Ok(Some(mut manifest)) = state::load_manifest() else {
        return;
    };
    let transport = codex_transport::codex_transport_from_env(sandboxed);
    let new_label = transport.manifest_label().to_string();
    let new_endpoint = transport.endpoint().map(ToString::to_string);
    if manifest.codex_transport == new_label && manifest.codex_endpoint == new_endpoint {
        return;
    }
    manifest.codex_transport = new_label;
    manifest.codex_endpoint = new_endpoint;
    if let Err(error) = state::write_manifest(&manifest) {
        tracing::warn!(%error, "codex-bridge watcher: failed to publish manifest update");
        return;
    }
    tracing::info!(
        transport = %manifest.codex_transport,
        endpoint = manifest.codex_endpoint.as_deref().unwrap_or("-"),
        "codex-bridge endpoint updated"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::state::DaemonManifest;
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

    fn stdio_manifest() -> DaemonManifest {
        DaemonManifest {
            version: "test".to_string(),
            pid: 1,
            endpoint: "http://127.0.0.1:0".to_string(),
            started_at: "2026-04-10T00:00:00Z".to_string(),
            token_path: "/tmp/token".to_string(),
            sandboxed: false,
            codex_transport: "stdio".to_string(),
            codex_endpoint: None,
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
                ("HARNESS_CODEX_WS_URL", None),
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

    #[test]
    fn apply_bridge_state_publishes_ws_endpoint_to_manifest() {
        with_temp_daemon_root(|| {
            state::ensure_daemon_dirs().expect("ensure");
            state::write_manifest(&stdio_manifest()).expect("write manifest");
            write_bridge_state(&sample_state()).expect("write state");

            apply_bridge_state_to_manifest(false);

            let reloaded = state::load_manifest()
                .expect("load manifest")
                .expect("manifest exists");
            assert_eq!(reloaded.codex_transport, "websocket");
            assert_eq!(
                reloaded.codex_endpoint.as_deref(),
                Some("ws://127.0.0.1:4500")
            );
        });
    }

    #[test]
    fn apply_bridge_state_is_noop_when_nothing_changes() {
        with_temp_daemon_root(|| {
            state::ensure_daemon_dirs().expect("ensure");
            let manifest = stdio_manifest();
            state::write_manifest(&manifest).expect("write manifest");

            // No bridge state, unsandboxed daemon → stdio default, which
            // matches the manifest we just wrote.
            apply_bridge_state_to_manifest(false);

            let reloaded = state::load_manifest()
                .expect("load manifest")
                .expect("manifest exists");
            assert_eq!(reloaded.codex_transport, manifest.codex_transport);
            assert_eq!(reloaded.codex_endpoint, manifest.codex_endpoint);
        });
    }

    #[test]
    fn apply_bridge_state_clears_endpoint_when_bridge_stops_in_sandbox_mode() {
        with_temp_daemon_root(|| {
            state::ensure_daemon_dirs().expect("ensure");
            state::write_manifest(&DaemonManifest {
                version: "test".to_string(),
                pid: 1,
                endpoint: "http://127.0.0.1:0".to_string(),
                started_at: "2026-04-10T00:00:00Z".to_string(),
                token_path: "/tmp/token".to_string(),
                sandboxed: true,
                codex_transport: "websocket".to_string(),
                codex_endpoint: Some("ws://127.0.0.1:4501".to_string()),
            })
            .expect("write manifest");

            // No bridge state file: sandboxed daemon falls back to the
            // default endpoint so the UI still gets a hint where to connect.
            apply_bridge_state_to_manifest(true);

            let reloaded = state::load_manifest()
                .expect("load manifest")
                .expect("manifest exists");
            assert_eq!(reloaded.codex_transport, "websocket");
            assert_eq!(
                reloaded.codex_endpoint.as_deref(),
                Some("ws://127.0.0.1:4500")
            );
        });
    }
}
