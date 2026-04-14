use std::fmt;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use sha2::{Digest, Sha256};

use crate::daemon::service;
use crate::daemon::state::{self, HostBridgeCapabilityManifest, HostBridgeManifest};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};

use super::client::BridgeClient;
use super::helpers::remove_if_exists;
use super::types::{
    BRIDGE_CAPABILITY_CODEX, BridgeState, BridgeStatusReport, DEFAULT_BRIDGE_SOCKET_NAME,
    FALLBACK_BRIDGE_SOCKET_PREFIX, FALLBACK_BRIDGE_SOCKET_SUFFIX, PersistedBridgeConfig,
    UNIX_SOCKET_PATH_LIMIT, status_report_from_state,
};

#[must_use]
pub fn bridge_state_path() -> PathBuf {
    state::daemon_root().join("bridge.json")
}

#[must_use]
pub fn bridge_config_path() -> PathBuf {
    state::daemon_root().join("bridge-config.json")
}

#[must_use]
pub(crate) fn bridge_lock_path() -> PathBuf {
    state::daemon_root().join(state::BRIDGE_LOCK_FILE)
}

/// Probe whether an exclusive `flock` on `bridge.lock` is currently held.
///
/// Returns `true` while `run_bridge_server` is actively running in the
/// foreground child. Safe to call from the sandboxed daemon (no subprocess
/// execution required).
#[must_use]
pub(crate) fn bridge_lock_is_held() -> bool {
    state::flock_is_held_at(&bridge_lock_path())
}

/// RAII guard that holds the exclusive `bridge.lock` flock.
///
/// Dropping the guard releases the lock so the kernel can clean up even on
/// panic or abnormal exit.
#[must_use = "drop the guard to release the bridge lock"]
pub(crate) struct BridgeLockGuard {
    _guard: state::FlockGuard,
}

impl fmt::Debug for BridgeLockGuard {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("BridgeLockGuard").finish()
    }
}

/// Acquire the exclusive `bridge.lock` for the current process lifetime.
///
/// Must be called before `run_bridge_server` binds the Unix socket so that a
/// racing second `harness bridge start` cannot unlink the live socket before
/// its own lock acquisition fails.
///
/// # Errors
/// Returns [`CliError`] when another bridge instance already holds the lock or
/// the lock file cannot be created.
pub(crate) fn acquire_bridge_lock_exclusive() -> Result<BridgeLockGuard, CliError> {
    state::ensure_daemon_dirs()?;
    state::acquire_flock_exclusive(&bridge_lock_path(), "bridge")
        .map_err(|_| {
            CliErrorKind::workflow_io(format!(
                "another `harness bridge` instance is already running at {}",
                bridge_lock_path().display()
            ))
            .into()
        })
        .map(|guard| BridgeLockGuard { _guard: guard })
}

#[must_use]
pub fn bridge_socket_path() -> PathBuf {
    bridge_socket_path_for_root(&state::daemon_root())
}

pub(super) fn bridge_socket_path_for_root(daemon_root: &Path) -> PathBuf {
    let preferred = daemon_root.join(DEFAULT_BRIDGE_SOCKET_NAME);
    if unix_socket_path_fits(&preferred) {
        return preferred;
    }
    fallback_bridge_socket_path(daemon_root)
}

pub(super) fn unix_socket_path_fits(path: &Path) -> bool {
    path.as_os_str().as_bytes().len() < UNIX_SOCKET_PATH_LIMIT
}

fn fallback_bridge_socket_path(daemon_root: &Path) -> PathBuf {
    let digest = hex::encode(Sha256::digest(daemon_root.as_os_str().as_bytes()));

    // When the daemon lives inside a macOS Group Container, the standard
    // `/tmp` fallback is blocked by the App Sandbox. Place the fallback
    // socket at the group container root instead, which every process
    // holding the matching `application-groups` entitlement can reach.
    // Shorten the hash suffix progressively so the combined path still
    // fits the 103-byte AF_UNIX `sun_path` limit even for longer homes.
    if let Some(group_container) = group_container_root(daemon_root) {
        for hash_len in [16usize, 12, 8, 4] {
            let file_name = format!("h-{}.sock", &digest[..hash_len]);
            let socket_path = group_container.join(file_name);
            if unix_socket_path_fits(&socket_path) {
                return socket_path;
            }
        }
    }

    PathBuf::from("/tmp").join(format!(
        "{FALLBACK_BRIDGE_SOCKET_PREFIX}{}{FALLBACK_BRIDGE_SOCKET_SUFFIX}",
        &digest[..16]
    ))
}

/// Returns `~/Library/Group Containers/{group}` when `daemon_root` is nested
/// inside a macOS Group Container, or `None` otherwise.
pub(super) fn group_container_root(daemon_root: &Path) -> Option<PathBuf> {
    let components: Vec<_> = daemon_root.components().collect();
    for (idx, window) in components.windows(3).enumerate() {
        if window[0].as_os_str() == "Library" && window[1].as_os_str() == "Group Containers" {
            let mut path = PathBuf::new();
            for component in &components[..=idx + 2] {
                path.push(component.as_os_str());
            }
            return Some(path);
        }
    }
    None
}

/// Load the persisted bridge state if it exists.
///
/// # Errors
/// Returns [`CliError`] when the on-disk state cannot be deserialized.
pub fn read_bridge_state() -> Result<Option<BridgeState>, CliError> {
    if !bridge_state_path().is_file() {
        return Ok(None);
    }
    read_json_typed(&bridge_state_path()).map(Some)
}

pub(super) fn read_bridge_config() -> Result<Option<PersistedBridgeConfig>, CliError> {
    if !bridge_config_path().is_file() {
        return Ok(None);
    }
    read_json_typed(&bridge_config_path())
        .map(|config: PersistedBridgeConfig| Some(config.normalized()))
}

pub(super) fn write_bridge_state(state: &BridgeState) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
    write_json_pretty(&bridge_state_path(), state)
}

pub(super) fn write_bridge_config(config: &PersistedBridgeConfig) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
    write_json_pretty(&bridge_config_path(), &config.clone().normalized())
}

pub(super) fn clear_bridge_state() -> Result<(), CliError> {
    let socket_path = read_bridge_state()?
        .map_or_else(bridge_socket_path, |state| PathBuf::from(state.socket_path));
    remove_if_exists(&bridge_state_path())?;
    remove_if_exists(&socket_path)?;
    // On macOS, unlinking a flocked file is legal: the kernel holds the inode
    // until the fd is closed, so the Drop on the BridgeLockGuard frame
    // (which runs after clear_bridge_state returns) releases the flock
    // naturally. The file is removed here so stale lock files do not
    // accumulate if the bridge crashes before a clean shutdown.
    remove_if_exists(&bridge_lock_path())?;
    Ok(())
}

/// Who is asking whether the bridge is running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivenessMode {
    /// Host-CLI path. The caller owns the state file; `flock` is the primary
    /// signal, a live RPC from the persisted socket/token pair is the
    /// secondary proof, and `pid_alive` is the last-resort fallback for
    /// backward-compatibility with pre-19.7.0 bridge CLIs that did not publish
    /// `bridge.lock`.
    HostAuthoritative,
    /// Daemon/consumer path. The caller **does not** own the state file.
    /// `flock` and a live RPC are accepted as liveness proof; `pid_alive` is
    /// never called (the daemon may be sandboxed and cannot reliably signal an
    /// unsandboxed pid), and stale state is **never deleted**.
    LockOnly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum BridgeProof {
    Lock,
    Rpc,
    Pid,
}

#[derive(Debug, Clone)]
pub(super) struct ResolvedRunningBridge {
    pub(super) state: BridgeState,
    pub(super) report: BridgeStatusReport,
    pub(super) proof: BridgeProof,
    pub(super) client: Option<BridgeClient>,
}

fn resolve_running_bridge_from_lock(
    state: &BridgeState,
    client: Option<BridgeClient>,
) -> Option<ResolvedRunningBridge> {
    if !bridge_lock_is_held() {
        return None;
    }
    Some(ResolvedRunningBridge {
        report: status_report_from_state(state),
        state: state.clone(),
        proof: BridgeProof::Lock,
        client,
    })
}

fn resolve_running_bridge_from_rpc(
    state: &BridgeState,
    client: Option<BridgeClient>,
) -> Option<ResolvedRunningBridge> {
    let client = client?;
    let report = client.status().ok()?;
    if !report.running {
        return None;
    }
    Some(ResolvedRunningBridge {
        state: state.clone(),
        report,
        proof: BridgeProof::Rpc,
        client: Some(client),
    })
}

#[must_use]
fn should_use_pid_fallback(mode: LivenessMode) -> bool {
    matches!(mode, LivenessMode::HostAuthoritative) && !service::sandboxed_from_env()
}

fn resolve_running_bridge_from_pid(
    mode: LivenessMode,
    state: &BridgeState,
    client: Option<BridgeClient>,
) -> Option<ResolvedRunningBridge> {
    if !should_use_pid_fallback(mode) || !pid_alive(state.pid) {
        return None;
    }
    Some(ResolvedRunningBridge {
        report: status_report_from_state(state),
        state: state.clone(),
        proof: BridgeProof::Pid,
        client,
    })
}

fn missing_lock_only_bridge_message(
    mode: LivenessMode,
    running: Option<&ResolvedRunningBridge>,
) -> Option<&'static str> {
    if running.is_none() && matches!(mode, LivenessMode::LockOnly) {
        return Some(
            "bridge watcher: bridge lock/RPC proof unavailable, treating bridge as not running (bridge.json preserved)",
        );
    }
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion in a leaf logging helper"
)]
fn log_bridge_resolution_debug(message: &'static str) {
    tracing::debug!("{message}");
}

pub(super) fn resolve_running_bridge(
    mode: LivenessMode,
) -> Result<Option<ResolvedRunningBridge>, CliError> {
    let Some(state) = read_bridge_state()? else {
        return Ok(None);
    };
    let client = BridgeClient::from_state(&state).ok();
    let running = resolve_running_bridge_from_lock(&state, client.clone())
        .or_else(|| resolve_running_bridge_from_rpc(&state, client.clone()))
        .or_else(|| resolve_running_bridge_from_pid(mode, &state, client));
    if let Some(message) = missing_lock_only_bridge_message(mode, running.as_ref()) {
        log_bridge_resolution_debug(message);
    }
    Ok(running)
}

/// Load the bridge state only when liveness can be confirmed.
///
/// On the [`LivenessMode::LockOnly`] path (sandboxed daemon consumer) the
/// function is purely read-only: it never deletes `bridge.json` regardless of
/// what it finds. Cleanup is the producer's responsibility.
///
/// On the [`LivenessMode::HostAuthoritative`] path the function first accepts a
/// live RPC from the persisted socket/token pair, then falls back to
/// `pid_alive` only when the current process is unsandboxed and the bridge
/// still looks like a legacy no-lock instance.
///
/// # Errors
/// Returns [`CliError`] when the state cannot be read.
pub fn load_running_bridge_state(mode: LivenessMode) -> Result<Option<BridgeState>, CliError> {
    Ok(resolve_running_bridge(mode)?.map(|running| running.state))
}

/// Build the daemon manifest view of the unified host bridge.
///
/// # Errors
/// Returns [`CliError`] when the persisted bridge state cannot be read.
pub fn host_bridge_manifest() -> Result<HostBridgeManifest, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::LockOnly)? else {
        return Ok(HostBridgeManifest::default());
    };
    Ok(HostBridgeManifest {
        running: true,
        socket_path: running.report.socket_path,
        capabilities: running.report.capabilities,
    })
}

/// Return the live `codex` capability manifest, if present.
///
/// # Errors
/// Returns [`CliError`] when the bridge state cannot be read.
pub fn running_codex_capability() -> Result<Option<HostBridgeCapabilityManifest>, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::LockOnly)? else {
        return Ok(None);
    };
    Ok(running
        .report
        .capabilities
        .get(BRIDGE_CAPABILITY_CODEX)
        .cloned())
}

/// Return the live `codex` WebSocket endpoint, if present.
///
/// # Errors
/// Returns [`CliError`] when the bridge state cannot be read.
pub fn codex_websocket_endpoint() -> Result<Option<String>, CliError> {
    Ok(running_codex_capability()?.and_then(|capability| capability.endpoint))
}

/// Refuse host-only bridge commands while running in the sandbox.
///
/// # Errors
/// Returns `SANDBOX001` when the current process is sandboxed.
pub fn ensure_host_context(feature: &'static str) -> Result<(), CliError> {
    if service::sandboxed_from_env() {
        return Err(CliErrorKind::sandbox_feature_disabled(feature).into());
    }
    Ok(())
}

#[must_use]
pub fn pid_alive(pid: u32) -> bool {
    let alive = Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    alive && !pid_is_zombie(pid)
}

fn pid_is_zombie(pid: u32) -> bool {
    Command::new("/bin/ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .is_some_and(|output| String::from_utf8_lossy(&output.stdout).trim().contains('Z'))
}

/// Read the current bridge status report.
///
/// # Errors
/// Returns [`CliError`] when the bridge state cannot be read.
pub fn status_report() -> Result<BridgeStatusReport, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)? else {
        return Ok(BridgeStatusReport::not_running());
    };
    Ok(running.report)
}
