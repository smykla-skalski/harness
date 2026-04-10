use std::env::{current_exe, split_paths, var, var_os};
use std::fs::File;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use clap::{Args, Subcommand};
use fs_err as fs;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::process::Command as TokioCommand;
use tokio::runtime::Runtime;
use tokio::signal::ctrl_c;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::workspace::utc_now;

use super::codex_transport;
use super::service;
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

/// How long to wait for a supervised codex process to exit after sending
/// `SIGTERM` before `codex-bridge stop` gives up and reports the failure.
const STOP_GRACE_PERIOD: Duration = Duration::from_secs(5);
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Top-level `harness codex-bridge` subcommand tree.
///
/// The bridge supervises an external `codex app-server` process on loopback
/// and publishes its endpoint so a sandboxed daemon can connect via WebSocket.
/// All subcommands must run outside the macOS App Sandbox; `start` and the
/// launch-agent helpers refuse to run when `HARNESS_SANDBOXED=1`.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum CodexBridgeCommand {
    /// Start a supervised `codex app-server` and publish its endpoint.
    Start(CodexBridgeStartArgs),
    /// Stop the running Codex bridge, if any.
    Stop(CodexBridgeStopArgs),
    /// Print the current bridge status.
    Status(CodexBridgeStatusArgs),
    /// Install a user `LaunchAgent` that auto-starts the Codex bridge at login.
    InstallLaunchAgent(CodexBridgeInstallLaunchAgentArgs),
    /// Remove the Codex bridge `LaunchAgent` and clean up state files.
    RemoveLaunchAgent(CodexBridgeRemoveLaunchAgentArgs),
}

#[derive(Debug, Clone, Args)]
pub struct CodexBridgeStartArgs {
    /// Port for `codex app-server --listen ws://127.0.0.1:<port>`.
    #[arg(long, env = "HARNESS_CODEX_WS_PORT")]
    pub port: Option<u16>,
    /// Explicit path to the `codex` binary. Resolved from PATH when absent.
    #[arg(long, value_name = "PATH")]
    pub codex_path: Option<PathBuf>,
    /// Detach from the terminal and run as a background supervisor.
    #[arg(long)]
    pub daemon: bool,
}

#[derive(Debug, Clone, Args)]
pub struct CodexBridgeStopArgs {
    /// Print the final status as JSON instead of a one-line summary.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct CodexBridgeStatusArgs {
    /// Print a plain one-line summary instead of the JSON payload.
    #[arg(long)]
    pub plain: bool,
}

#[derive(Debug, Clone, Args)]
pub struct CodexBridgeInstallLaunchAgentArgs {
    /// Port for the bridge `LaunchAgent` to pass to `codex-bridge start`.
    #[arg(long)]
    pub port: Option<u16>,
}

#[derive(Debug, Clone, Args)]
pub struct CodexBridgeRemoveLaunchAgentArgs {
    /// Print confirmation as JSON.
    #[arg(long)]
    pub json: bool,
}

/// Serialized snapshot of the bridge's live state for `status` / `stop`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexBridgeStatusReport {
    /// `true` when the bridge PID is still alive on the host.
    pub running: bool,
    /// Loopback WebSocket URL if a bridge state file is present.
    pub endpoint: Option<String>,
    /// PID of the supervised codex app-server, when known.
    pub pid: Option<u32>,
    /// Port the bridge published, when known.
    pub port: Option<u16>,
    /// ISO 8601 timestamp the bridge first registered the state file.
    pub started_at: Option<String>,
    /// Best-effort codex binary version string from the bridge state file.
    pub codex_version: Option<String>,
    /// Seconds since the bridge started, computed from `started_at`.
    pub uptime_seconds: Option<u64>,
}

impl CodexBridgeStatusReport {
    #[must_use]
    pub const fn not_running() -> Self {
        Self {
            running: false,
            endpoint: None,
            pid: None,
            port: None,
            started_at: None,
            codex_version: None,
            uptime_seconds: None,
        }
    }
}

impl Execute for CodexBridgeCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Start(args) => args.execute(context),
            Self::Stop(args) => args.execute(context),
            Self::Status(args) => args.execute(context),
            Self::InstallLaunchAgent(args) => args.execute(context),
            Self::RemoveLaunchAgent(args) => args.execute(context),
        }
    }
}

impl Execute for CodexBridgeStatusArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let report = status_report()?;
        if self.plain {
            print_status_plain(&report);
        } else {
            let json = serde_json::to_string_pretty(&report).map_err(|error| {
                CliError::from(CliErrorKind::workflow_serialize(error.to_string()))
            })?;
            println!("{json}");
        }
        Ok(0)
    }
}

impl Execute for CodexBridgeStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let report = stop_bridge()?;
        if self.json {
            let json = serde_json::to_string_pretty(&report).map_err(|error| {
                CliError::from(CliErrorKind::workflow_serialize(error.to_string()))
            })?;
            println!("{json}");
        } else {
            print_status_plain(&report);
        }
        Ok(0)
    }
}

/// Build a status report for the bridge by combining the persisted state file
/// with a live PID liveness probe.
///
/// # Errors
/// Returns a workflow parse error if the bridge state file exists but cannot
/// be decoded. A missing file returns `not_running`, not an error.
pub fn status_report() -> Result<CodexBridgeStatusReport, CliError> {
    let Some(state) = read_bridge_state()? else {
        return Ok(CodexBridgeStatusReport::not_running());
    };
    let running = pid_alive(state.pid);
    let uptime_seconds = uptime_from_started_at(&state.started_at);
    Ok(CodexBridgeStatusReport {
        running,
        endpoint: Some(state.endpoint),
        pid: Some(state.pid),
        port: Some(state.port),
        started_at: Some(state.started_at),
        codex_version: state.codex_version,
        uptime_seconds,
    })
}

/// Send `SIGTERM` to the supervised codex process (if any), wait for it to
/// exit, clear the state files, and return the final status. Idempotent: a
/// missing state file is a successful no-op.
///
/// # Errors
/// Returns a workflow I/O error when `/bin/kill` cannot be invoked, or when
/// state file cleanup fails.
pub fn stop_bridge() -> Result<CodexBridgeStatusReport, CliError> {
    let Some(state) = read_bridge_state()? else {
        // Clean up any stray pid file just in case, then report not-running.
        clear_bridge_state()?;
        return Ok(CodexBridgeStatusReport::not_running());
    };

    let pid = state.pid;
    if pid_alive(pid) {
        send_signal(pid, "-TERM")?;
        wait_until_dead(pid, STOP_GRACE_PERIOD)?;
    }

    let uptime_seconds = uptime_from_started_at(&state.started_at);
    clear_bridge_state()?;
    Ok(CodexBridgeStatusReport {
        running: false,
        endpoint: Some(state.endpoint),
        pid: Some(pid),
        port: Some(state.port),
        started_at: Some(state.started_at),
        codex_version: state.codex_version,
        uptime_seconds,
    })
}

fn print_status_plain(report: &CodexBridgeStatusReport) {
    if report.running {
        let endpoint = report.endpoint.as_deref().unwrap_or("?");
        let pid = report
            .pid
            .map_or_else(|| "?".to_string(), |pid| pid.to_string());
        println!("running at {endpoint} (pid {pid})");
    } else if let Some(endpoint) = report.endpoint.as_deref() {
        println!("not running (stale endpoint {endpoint})");
    } else {
        println!("not running");
    }
}

/// Probe liveness of `pid` via `/bin/kill -0`. Returns `false` on any error,
/// since an inaccessible PID is equivalent to a dead one for bridge purposes.
/// Swallows stderr so routine "no such process" probes do not spam logs.
#[must_use]
pub fn pid_alive(pid: u32) -> bool {
    Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Invoke `/bin/kill -<signal> <pid>`. `-0` can be used for liveness probes,
/// but this helper is meant for side-effectful signals where a failure to
/// deliver is a real error.
fn send_signal(pid: u32, signal: &str) -> Result<(), CliError> {
    let status = Command::new("/bin/kill")
        .args([signal, &pid.to_string()])
        .status()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "run /bin/kill {signal} {pid}: {error}"
            )))
        })?;

    if status.success() {
        return Ok(());
    }

    // Kill failing usually means the PID is gone already, which we treat as
    // idempotent for -TERM. Surface other signal failures loudly.
    if signal == "-TERM" && !pid_alive(pid) {
        return Ok(());
    }

    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "/bin/kill {signal} {pid} exited with {status}"
    ))))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn wait_until_dead(pid: u32, grace: Duration) -> Result<(), CliError> {
    let start = Instant::now();
    while start.elapsed() < grace {
        if !pid_alive(pid) {
            tracing::info!(pid, "codex-bridge: supervised process exited");
            return Ok(());
        }
        thread::sleep(STOP_POLL_INTERVAL);
    }

    tracing::warn!(pid, "codex-bridge: process still alive after SIGTERM grace");
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "codex-bridge stop: pid {pid} still alive after {}s",
        grace.as_secs()
    ))))
}

impl Execute for CodexBridgeStartArgs {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion; tokio-rs/tracing#553"
    )]
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("codex-bridge-start")?;

        let port = self.port.unwrap_or(DEFAULT_CODEX_BRIDGE_PORT);
        let codex_binary = resolve_codex_binary(self.codex_path.as_deref())?;

        if self.daemon {
            return start_detached(&codex_binary, port);
        }

        let codex_version = detect_codex_version(&codex_binary);
        let listen_address = format!("ws://127.0.0.1:{port}");
        tracing::info!(
            binary = %codex_binary.display(),
            %listen_address,
            version = codex_version.as_deref().unwrap_or("unknown"),
            "codex-bridge: starting supervised codex app-server"
        );

        let runtime = Runtime::new().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create codex-bridge tokio runtime: {error}"
            )))
        })?;

        runtime.block_on(run_bridge_supervisor(
            &codex_binary,
            &listen_address,
            port,
            codex_version,
        ))
    }
}

fn start_detached(codex_binary: &Path, port: u16) -> Result<i32, CliError> {
    let harness = current_exe().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "resolve current harness binary: {error}"
        )))
    })?;
    let args = [
        "codex-bridge",
        "start",
        "--port",
        &port.to_string(),
        "--codex-path",
        &codex_binary.display().to_string(),
    ];
    let stdout_path = state::daemon_root().join("codex-bridge.stdout.log");
    let stderr_path = state::daemon_root().join("codex-bridge.stderr.log");
    state::ensure_daemon_dirs()?;
    let stdout = File::create(&stdout_path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create {}: {error}",
            stdout_path.display()
        )))
    })?;
    let stderr = File::create(&stderr_path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create {}: {error}",
            stderr_path.display()
        )))
    })?;
    let child = Command::new(&harness)
        .args(args)
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "spawn detached bridge: {error}"
            )))
        })?;
    println!("codex-bridge started in background (pid {})", child.id());
    Ok(0)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn run_bridge_supervisor(
    codex_binary: &Path,
    listen_address: &str,
    port: u16,
    codex_version: Option<String>,
) -> Result<i32, CliError> {
    let mut child = TokioCommand::new(codex_binary)
        .args(["app-server", "--listen", listen_address])
        .stdin(Stdio::null())
        .spawn()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "spawn codex app-server: {error}"
            )))
        })?;

    let child_pid = child.id().unwrap_or(0);
    tracing::info!(pid = child_pid, "codex-bridge: codex app-server spawned");

    write_bridge_state(&CodexBridgeState {
        endpoint: listen_address.to_string(),
        pid: child_pid,
        started_at: utc_now(),
        port,
        codex_version,
    })?;
    write_bridge_pid(child_pid)?;

    let exit_code = tokio::select! {
        status = child.wait() => {
            let status = status.map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "wait for codex app-server: {error}"
                )))
            })?;
            tracing::info!(%status, "codex-bridge: codex app-server exited");
            status.code().unwrap_or(1)
        }
        () = async { ctrl_c().await.ok(); } => {
            tracing::info!("codex-bridge: received interrupt, stopping child");
            let _ = child.kill().await;
            0
        }
    };

    clear_bridge_state()?;
    Ok(exit_code)
}

/// Resolve the `codex` binary, either from an explicit path or by walking
/// `PATH` manually. Avoids pulling in a `which` crate for a single lookup.
///
/// # Errors
/// Returns a workflow I/O error when no executable `codex` can be found.
fn resolve_codex_binary(explicit: Option<&Path>) -> Result<PathBuf, CliError> {
    if let Some(path) = explicit {
        if path.is_file() {
            return Ok(path.to_path_buf());
        }
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "codex binary not found at {}",
            path.display()
        ))));
    }

    if let Some(path) = find_on_path("codex") {
        return Ok(path);
    }

    Err(CliError::from(CliErrorKind::workflow_io(
        "codex binary not found on PATH; use --codex-path to specify it".to_string(),
    )))
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path_var = var_os("PATH")?;
    for directory in split_paths(&path_var) {
        let candidate = directory.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Best-effort version detection by running `codex --version` before spawn.
/// Returns `None` on any failure without stopping the bridge.
fn detect_codex_version(binary: &Path) -> Option<String> {
    let output = Command::new(binary)
        .arg("--version")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_string())
}

fn uptime_from_started_at(started_at: &str) -> Option<u64> {
    let started: DateTime<Utc> = DateTime::parse_from_rfc3339(started_at).ok()?.into();
    let now = Utc::now();
    let duration = now.signed_duration_since(started);
    u64::try_from(duration.num_seconds()).ok()
}

impl Execute for CodexBridgeInstallLaunchAgentArgs {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion; tokio-rs/tracing#553"
    )]
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("codex-bridge-install-launch-agent")?;

        let harness_binary = current_exe().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "resolve current harness binary: {error}"
            )))
        })?;

        resolve_codex_binary(None).map_err(|_| {
            CliError::from(CliErrorKind::workflow_io(
                "codex binary not found on PATH; install codex before adding the launch agent"
                    .to_string(),
            ))
        })?;

        let port = self.port.unwrap_or(DEFAULT_CODEX_BRIDGE_PORT);
        let plist = render_codex_bridge_launch_agent_plist(&harness_binary, port);

        let plist_path = codex_bridge_launch_agent_plist_path()?;
        if let Some(parent) = plist_path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "create launch agent dir: {error}"
                )))
            })?;
        }
        write_text(&plist_path, &plist)?;

        if cfg!(target_os = "macos") {
            best_effort_bootout_bridge();
            bootstrap_bridge_agent(&plist_path)?;
        }

        tracing::info!(path = %plist_path.display(), "codex-bridge: installed launch agent plist");
        println!("installed {}", plist_path.display());
        Ok(0)
    }
}

impl Execute for CodexBridgeRemoveLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("codex-bridge-remove-launch-agent")?;

        let plist_path = codex_bridge_launch_agent_plist_path()?;
        let existed = plist_path.is_file();
        if existed && cfg!(target_os = "macos") {
            best_effort_bootout_bridge();
        }
        if existed {
            fs::remove_file(&plist_path).map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "remove codex-bridge plist: {error}"
                )))
            })?;
        }
        clear_bridge_state()?;

        if self.json {
            let json = serde_json::json!({
                "removed": existed,
                "path": plist_path.display().to_string(),
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&json).unwrap_or_default()
            );
        } else if existed {
            println!("removed {}", plist_path.display());
        } else {
            println!("not installed");
        }
        Ok(0)
    }
}

fn codex_bridge_launch_agent_plist_path() -> Result<PathBuf, CliError> {
    let home = var("HOME").map_err(|_| {
        CliError::from(CliErrorKind::workflow_io(
            "HOME is not set; cannot determine LaunchAgent path".to_string(),
        ))
    })?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{CODEX_BRIDGE_LAUNCH_AGENT_LABEL}.plist")))
}

fn render_codex_bridge_launch_agent_plist(harness_binary: &Path, port: u16) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{binary}</string>
    <string>codex-bridge</string>
    <string>start</string>
    <string>--port</string>
    <string>{port}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HARNESS_APP_GROUP_ID</key>
    <string>Q498EB36N4.io.harnessmonitor</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = CODEX_BRIDGE_LAUNCH_AGENT_LABEL,
        binary = harness_binary.display(),
        stdout = state::daemon_root()
            .join("codex-bridge.stdout.log")
            .display(),
        stderr = state::daemon_root()
            .join("codex-bridge.stderr.log")
            .display(),
    )
}

fn bridge_launchd_service_target() -> String {
    format!(
        "gui/{}/{CODEX_BRIDGE_LAUNCH_AGENT_LABEL}",
        uzers::get_current_uid()
    )
}

fn best_effort_bootout_bridge() {
    let target = bridge_launchd_service_target();
    let _ = Command::new("launchctl")
        .args(["bootout", &target])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn bootstrap_bridge_agent(plist_path: &Path) -> Result<(), CliError> {
    let domain = format!("gui/{}", uzers::get_current_uid());
    let output = Command::new("launchctl")
        .args(["bootstrap", &domain, &plist_path.display().to_string()])
        .output()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "run launchctl bootstrap: {error}"
            )))
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if !stderr.to_ascii_lowercase().contains("already loaded")
            && !stderr.to_ascii_lowercase().contains("already bootstrapped")
        {
            return Err(CliError::from(CliErrorKind::workflow_io(format!(
                "launchctl bootstrap failed: {stderr}"
            ))));
        }
    }
    Ok(())
}

/// Refuse to run a codex-bridge command that requires host privileges when
/// the process is running under the macOS App Sandbox.
///
/// # Errors
/// Returns `SandboxFeatureDisabled` when `HARNESS_SANDBOXED` is truthy.
pub fn ensure_host_context(feature: &'static str) -> Result<(), CliError> {
    if service::sandboxed_from_env() {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            feature,
        )));
    }
    Ok(())
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

    fn live_state_for_current_process() -> CodexBridgeState {
        CodexBridgeState {
            endpoint: "ws://127.0.0.1:4500".to_string(),
            pid: std::process::id(),
            started_at: "2026-04-10T12:00:00Z".to_string(),
            port: 4500,
            codex_version: Some("0.102.0".to_string()),
        }
    }

    /// A PID that is guaranteed not to belong to a live process on macOS.
    /// PID 1 (launchd) is always alive on macOS, so we pick a high number
    /// that no normal system would assign. If a process happens to own it
    /// the test will fail loudly, which is the intended behavior.
    const DEFINITELY_DEAD_PID: u32 = 2_000_000_000;

    #[test]
    fn pid_alive_reports_true_for_current_process() {
        assert!(pid_alive(std::process::id()));
    }

    #[test]
    fn pid_alive_reports_false_for_unlikely_pid() {
        assert!(!pid_alive(DEFINITELY_DEAD_PID));
    }

    #[test]
    fn status_report_reports_not_running_when_state_missing() {
        with_temp_daemon_root(|| {
            let report = status_report().expect("status");
            assert_eq!(report, CodexBridgeStatusReport::not_running());
        });
    }

    #[test]
    fn status_report_reports_running_when_pid_alive() {
        with_temp_daemon_root(|| {
            write_bridge_state(&live_state_for_current_process()).expect("write state");
            let report = status_report().expect("status");
            assert!(report.running);
            assert_eq!(report.endpoint.as_deref(), Some("ws://127.0.0.1:4500"));
            assert_eq!(report.pid, Some(std::process::id()));
            assert_eq!(report.port, Some(4500));
        });
    }

    #[test]
    fn status_report_reports_stale_state_as_not_running() {
        with_temp_daemon_root(|| {
            let mut stale = live_state_for_current_process();
            stale.pid = DEFINITELY_DEAD_PID;
            write_bridge_state(&stale).expect("write state");
            let report = status_report().expect("status");
            assert!(!report.running);
            assert_eq!(report.pid, Some(DEFINITELY_DEAD_PID));
            assert_eq!(report.endpoint.as_deref(), Some("ws://127.0.0.1:4500"));
        });
    }

    #[test]
    fn stop_bridge_is_idempotent_when_state_missing() {
        with_temp_daemon_root(|| {
            let report = stop_bridge().expect("stop");
            assert_eq!(report, CodexBridgeStatusReport::not_running());
            assert!(!codex_endpoint_path().exists());
            assert!(!codex_bridge_pid_path().exists());
        });
    }

    #[test]
    fn stop_bridge_clears_stale_state_without_signaling() {
        with_temp_daemon_root(|| {
            let mut stale = live_state_for_current_process();
            stale.pid = DEFINITELY_DEAD_PID;
            write_bridge_state(&stale).expect("write state");
            write_bridge_pid(DEFINITELY_DEAD_PID).expect("write pid");

            let report = stop_bridge().expect("stop");
            assert!(!report.running);
            assert_eq!(report.pid, Some(DEFINITELY_DEAD_PID));
            assert!(!codex_endpoint_path().exists());
            assert!(!codex_bridge_pid_path().exists());
        });
    }

    #[test]
    fn resolve_codex_binary_returns_explicit_path_when_file_exists() {
        with_temp_daemon_root(|| {
            let tmp = tempdir().expect("tempdir");
            let binary = tmp.path().join("codex");
            fs::write(&binary, "#!/bin/sh\n").expect("write");
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755))
                .expect("chmod");
            let result = resolve_codex_binary(Some(&binary)).expect("resolve");
            assert_eq!(result, binary);
        });
    }

    #[test]
    fn resolve_codex_binary_fails_when_explicit_path_missing() {
        with_temp_daemon_root(|| {
            let error =
                resolve_codex_binary(Some(Path::new("/nonexistent/codex"))).expect_err("must fail");
            assert!(error.message().contains("not found at"));
        });
    }

    #[test]
    fn resolve_codex_binary_finds_on_path() {
        let tmp = tempdir().expect("tempdir");
        let binary = tmp.path().join("codex");
        fs::write(&binary, "#!/bin/sh\n").expect("write");
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).expect("chmod");

        temp_env::with_var("PATH", Some(tmp.path().to_str().expect("utf8")), || {
            let result = resolve_codex_binary(None).expect("resolve");
            assert_eq!(result, binary);
        });
    }

    #[test]
    fn resolve_codex_binary_fails_when_not_on_path() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_var("PATH", Some(tmp.path().to_str().expect("utf8")), || {
            let error = resolve_codex_binary(None).expect_err("must fail");
            assert!(error.message().contains("not found on PATH"));
        });
    }

    #[test]
    fn is_executable_returns_false_for_missing_file() {
        assert!(!is_executable(Path::new("/nonexistent/binary")));
    }

    #[test]
    fn is_executable_returns_false_for_non_executable_file() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("script");
        fs::write(&path, "data").expect("write");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).expect("chmod");
        assert!(!is_executable(&path));
    }

    #[test]
    fn is_executable_returns_true_for_executable_file() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("script");
        fs::write(&path, "#!/bin/sh\n").expect("write");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        assert!(is_executable(&path));
    }

    #[test]
    fn detect_codex_version_returns_none_for_missing_binary() {
        assert!(detect_codex_version(Path::new("/nonexistent/codex")).is_none());
    }

    #[test]
    fn render_codex_bridge_plist_contains_expected_fields() {
        let plist =
            render_codex_bridge_launch_agent_plist(Path::new("/usr/local/bin/harness"), 4500);
        assert!(plist.contains(CODEX_BRIDGE_LAUNCH_AGENT_LABEL));
        assert!(plist.contains("codex-bridge"));
        assert!(plist.contains("start"));
        assert!(plist.contains("<string>4500</string>"));
        assert!(plist.contains("Aqua"));
        assert!(plist.contains("Interactive"));
        assert!(plist.contains("/usr/local/bin/harness"));
    }

    #[test]
    fn render_codex_bridge_plist_uses_custom_port() {
        let plist =
            render_codex_bridge_launch_agent_plist(Path::new("/usr/local/bin/harness"), 9999);
        assert!(plist.contains("<string>9999</string>"));
    }

    #[test]
    fn codex_bridge_launch_agent_plist_path_uses_home() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_var("HOME", Some(tmp.path().to_str().expect("utf8")), || {
            let path = codex_bridge_launch_agent_plist_path().expect("path");
            assert!(path.ends_with("Library/LaunchAgents/io.harness.codex-bridge.plist"));
            assert!(path.starts_with(tmp.path()));
        });
    }

    #[test]
    fn install_launch_agent_refuses_when_sandboxed() {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let args = CodexBridgeInstallLaunchAgentArgs { port: None };
            let ctx = AppContext::production();
            let error = args.execute(&ctx).expect_err("must refuse");
            assert_eq!(error.code(), "SANDBOX001");
        });
    }

    #[test]
    fn remove_launch_agent_refuses_when_sandboxed() {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let args = CodexBridgeRemoveLaunchAgentArgs { json: false };
            let ctx = AppContext::production();
            let error = args.execute(&ctx).expect_err("must refuse");
            assert_eq!(error.code(), "SANDBOX001");
        });
    }

    #[test]
    fn start_refuses_when_sandboxed() {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let args = CodexBridgeStartArgs {
                port: None,
                codex_path: None,
                daemon: false,
            };
            let ctx = AppContext::production();
            let error = args.execute(&ctx).expect_err("must refuse");
            assert_eq!(error.code(), "SANDBOX001");
        });
    }

    #[test]
    fn ensure_host_context_refuses_when_sandboxed() {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let error = ensure_host_context("test").expect_err("must refuse");
            assert_eq!(error.code(), "SANDBOX001");
        });
    }

    #[test]
    fn ensure_host_context_allows_when_unsandboxed() {
        temp_env::with_var("HARNESS_SANDBOXED", Option::<&str>::None, || {
            ensure_host_context("test").expect("allowed outside sandbox");
        });
    }
}
