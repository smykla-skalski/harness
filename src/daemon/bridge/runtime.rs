use std::collections::{BTreeMap, BTreeSet};
use std::fs::Permissions;
use std::io::ErrorKind;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use fs_err as fs;

use crate::daemon::state::{self, HostBridgeCapabilityManifest};
use crate::errors::{CliError, CliErrorKind};

use super::bridge_state::{
    LivenessMode, acquire_bridge_lock_exclusive, bridge_lock_path, clear_bridge_state,
    resolve_running_bridge, write_bridge_config,
};
use super::core::{BridgeAgentTuiMetadata, ResolvedBridgeConfig};
use super::helpers::{remove_if_exists, stringify_metadata_map};
use super::server::BridgeServer;
use super::stream_handler::handle_stream;
use super::types::{
    BRIDGE_CAPABILITY_ACP, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX, BridgeCapability,
};

const BRIDGE_ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(50);

pub(super) fn matches_running_config(config: &ResolvedBridgeConfig) -> Result<bool, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)? else {
        return Ok(false);
    };
    if running.report.socket_path.as_deref() != Some(config.socket_path.to_string_lossy().as_ref())
    {
        return Ok(false);
    }
    let running_capabilities: BTreeSet<&str> = running
        .report
        .capabilities
        .keys()
        .map(String::as_str)
        .collect();
    let requested_capabilities: BTreeSet<&str> = config
        .capabilities
        .iter()
        .map(|capability| capability.name())
        .collect();
    if running_capabilities != requested_capabilities {
        return Ok(false);
    }
    if let Some(codex_binary) = config.codex_binary.as_ref()
        && let Some(codex) = running.report.capabilities.get(BRIDGE_CAPABILITY_CODEX)
    {
        let port_matches = codex
            .metadata
            .get("port")
            .and_then(|value| value.parse::<u16>().ok())
            == Some(config.codex_port);
        let binary_matches =
            codex.metadata.get("binary_path") == Some(&codex_binary.display().to_string());
        return Ok(port_matches && binary_matches);
    }
    Ok(true)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "each branch handles a distinct server-lifecycle step; splitting further would obscure the flow"
)]
pub(super) fn run_bridge_server(config: &ResolvedBridgeConfig) -> Result<i32, CliError> {
    state::ensure_daemon_dirs()?;
    // Acquire the bridge lock BEFORE unlinking the socket so a racing second
    // `harness-bridge start` cannot unlink the live socket of the first
    // instance before failing its own lock acquisition.
    let _bridge_lock = acquire_bridge_lock_exclusive()?;
    tracing::info!(path = %bridge_lock_path().display(), "bridge lock acquired");
    remove_if_exists(&config.socket_path)?;
    let listener = UnixListener::bind(&config.socket_path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "bind bridge socket {}: {error}",
            config.socket_path.display()
        ))
    })?;
    // Arm a socket guard immediately after bind so that any subsequent error
    // return, panic, or unexpected accept failure still unlinks the socket.
    // The happy-path cleanup is handled by `clear_bridge_state()` below and
    // disarms the guard so it does not double-unlink.
    let mut socket_guard = BridgeSocketGuard::new(config.socket_path.clone());
    let mut state_guard = BridgeStateGuard::new();
    fs::set_permissions(&config.socket_path, Permissions::from_mode(0o600)).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "set bridge socket permissions {}: {error}",
            config.socket_path.display()
        ))
    })?;
    listener.set_nonblocking(true).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "configure bridge socket nonblocking {}: {error}",
            config.socket_path.display()
        ))
    })?;

    let token = state::ensure_auth_token()?;
    let capabilities = initial_capabilities(config);
    let server = Arc::new(BridgeServer::new(
        token,
        config.socket_path.clone(),
        config.persisted.clone(),
        capabilities,
    ));
    super::shutdown_signals::install(Arc::clone(&server))?;
    write_bridge_config(&config.persisted)?;
    if config.capabilities.contains(&BridgeCapability::Codex) {
        server.enable_codex(config)?;
    }
    server.persist_state()?;
    super::audit::record_bridge_started(config);

    while !server.shutdown_requested() {
        match listener.accept() {
            Ok((stream, _addr)) => {
                // macOS inherits the listener's O_NONBLOCK on accept while Linux does
                // not, and every handler below this point expects blocking reads. Left
                // nonblocking, an attach connection tears itself down: its input proxy
                // reads WouldBlock before the user types, treats it as fatal, and shuts
                // down the socket that carries the agent's output.
                stream.set_nonblocking(false).map_err(|error| {
                    CliErrorKind::workflow_io(format!(
                        "configure bridge connection blocking: {error}"
                    ))
                })?;
                spawn_bridge_connection_handler(&server, stream)?;
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(BRIDGE_ACCEPT_POLL_INTERVAL);
            }
            Err(error) => {
                return Err(CliErrorKind::workflow_io(format!(
                    "accept bridge connection: {error}"
                ))
                .into());
            }
        }
    }
    server.cleanup();
    clear_bridge_state()?;
    super::audit::record_bridge_stopped();
    socket_guard.disarm();
    state_guard.disarm();
    Ok(0)
}

fn spawn_bridge_connection_handler(
    server: &Arc<BridgeServer>,
    stream: UnixStream,
) -> Result<(), CliError> {
    let server = Arc::clone(server);
    thread::Builder::new()
        .name("harness-bridge-rpc".to_string())
        .spawn(move || handle_bridge_connection_thread(&server, &stream))
        .map(|_| ())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn bridge RPC handler: {error}")).into()
        })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn handle_bridge_connection_thread(server: &Arc<BridgeServer>, stream: &UnixStream) {
    if let Err(error) = handle_stream(server, stream) {
        tracing::warn!(%error, "bridge RPC handler failed");
    }
}

/// RAII guard that unlinks the bridge unix socket file on drop, unless
/// `disarm()` is called. Installed by `run_bridge_server` right after
/// `bind()` so any error return, panic, or unexpected exit still cleans
/// up the socket file (signal-delivered `SIGKILL` remains a leak vector
/// and is handled by `mise run clean:stale`).
pub(super) struct BridgeSocketGuard {
    path: PathBuf,
    armed: bool,
}

impl BridgeSocketGuard {
    pub(super) fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    pub(super) fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for BridgeSocketGuard {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score past the default threshold"
    )]
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if let Err(error) = fs::remove_file(&self.path)
            && error.kind() != ErrorKind::NotFound
        {
            tracing::warn!(
                path = %self.path.display(),
                %error,
                "failed to unlink bridge socket on drop"
            );
        }
    }
}

/// RAII guard that removes persisted bridge state on drop unless `disarm()`
/// is called. Installed by `run_bridge_server` so startup failures do not
/// leave stale bridge state behind.
struct BridgeStateGuard {
    armed: bool,
}

impl BridgeStateGuard {
    fn new() -> Self {
        Self { armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for BridgeStateGuard {
    #[expect(
        clippy::cognitive_complexity,
        reason = "drop path is tiny; tracing macro expansion trips the lint"
    )]
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if let Err(error) = clear_bridge_state() {
            tracing::warn!(%error, "failed to clear bridge state on drop");
        }
    }
}

pub(super) fn initial_capabilities(
    config: &ResolvedBridgeConfig,
) -> BTreeMap<String, HostBridgeCapabilityManifest> {
    let mut capabilities = BTreeMap::new();
    if config.capabilities.contains(&BridgeCapability::AgentTui) {
        capabilities.insert(
            BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "unix".to_string(),
                endpoint: Some(config.socket_path.display().to_string()),
                metadata: stringify_metadata_map(&BridgeAgentTuiMetadata { active_sessions: 0 }),
            },
        );
    }
    if config.capabilities.contains(&BridgeCapability::Acp) {
        capabilities.insert(
            BRIDGE_CAPABILITY_ACP.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "unix".to_string(),
                endpoint: Some(config.socket_path.display().to_string()),
                metadata: BTreeMap::new(),
            },
        );
    }
    capabilities
}
