use std::collections::{BTreeMap, BTreeSet};
use std::env::{current_exe, split_paths, var, var_os};
use std::fmt;
use std::fs::File;
use std::fs::Permissions;
use std::io::{BufRead, BufReader, ErrorKind, Write as _};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio, id as process_id};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use clap::{Args, Subcommand, ValueEnum};
use fs_err as fs;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::workspace::utc_now;

use super::agent_tui::{
    AgentTuiInputRequest, AgentTuiLaunchProfile, AgentTuiProcess, AgentTuiResizeRequest,
    AgentTuiSize, AgentTuiSnapshot, AgentTuiSnapshotContext, AgentTuiStatus, send_initial_prompt,
    snapshot_from_process, spawn_agent_tui_process,
};
use super::discovery::{self, AdoptionOutcome};
use super::state::{self, HostBridgeCapabilityManifest, HostBridgeManifest};

pub const BRIDGE_LAUNCH_AGENT_LABEL: &str = "io.harness.bridge";
pub const BRIDGE_CAPABILITY_CODEX: &str = "codex";
pub const BRIDGE_CAPABILITY_AGENT_TUI: &str = "agent-tui";
pub const DEFAULT_CODEX_BRIDGE_PORT: u16 = 4500;
pub const CODEX_BRIDGE_PORT_ENV: &str = "HARNESS_CODEX_WS_PORT";

const STOP_GRACE_PERIOD: Duration = Duration::from_secs(5);
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);
const DETACHED_START_TIMEOUT: Duration = Duration::from_secs(5);
const DETACHED_START_POLL_INTERVAL: Duration = Duration::from_millis(50);
const WATCH_DEBOUNCE: Duration = Duration::from_millis(200);
const DEFAULT_BRIDGE_SOCKET_NAME: &str = "bridge.sock";
const FALLBACK_BRIDGE_SOCKET_PREFIX: &str = "h-bridge-";
const FALLBACK_BRIDGE_SOCKET_SUFFIX: &str = ".sock";
const UNIX_SOCKET_PATH_LIMIT: usize = if cfg!(target_os = "macos") { 103 } else { 107 };

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum BridgeCapability {
    Codex,
    #[serde(rename = "agent-tui")]
    #[value(name = "agent-tui")]
    AgentTui,
}

impl BridgeCapability {
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Codex => BRIDGE_CAPABILITY_CODEX,
            Self::AgentTui => BRIDGE_CAPABILITY_AGENT_TUI,
        }
    }

    #[must_use]
    pub const fn sandbox_feature(self) -> &'static str {
        match self {
            Self::Codex => "codex.host-bridge",
            Self::AgentTui => "agent-tui.host-bridge",
        }
    }

    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            BRIDGE_CAPABILITY_CODEX => Some(Self::Codex),
            BRIDGE_CAPABILITY_AGENT_TUI => Some(Self::AgentTui),
            _ => None,
        }
    }
}

#[must_use]
pub fn compiled_capabilities() -> BTreeSet<BridgeCapability> {
    [BridgeCapability::Codex, BridgeCapability::AgentTui]
        .into_iter()
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeState {
    pub socket_path: String,
    pub pid: u32,
    pub started_at: String,
    pub token_path: String,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeStatusReport {
    pub running: bool,
    pub socket_path: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<String>,
    pub uptime_seconds: Option<u64>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

impl BridgeStatusReport {
    #[must_use]
    pub fn not_running() -> Self {
        Self {
            running: false,
            socket_path: None,
            pid: None,
            started_at: None,
            uptime_seconds: None,
            capabilities: BTreeMap::new(),
        }
    }
}

#[must_use]
fn status_report_from_state(state: &BridgeState) -> BridgeStatusReport {
    BridgeStatusReport {
        running: true,
        socket_path: Some(state.socket_path.clone()),
        pid: Some(state.pid),
        started_at: Some(state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&state.started_at),
        capabilities: state.capabilities.clone(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct PersistedBridgeConfig {
    #[serde(default)]
    capabilities: Vec<BridgeCapability>,
    #[serde(default)]
    socket_path: Option<PathBuf>,
    #[serde(default)]
    codex_port: Option<u16>,
    #[serde(default)]
    codex_path: Option<PathBuf>,
}

impl PersistedBridgeConfig {
    #[must_use]
    fn normalized(mut self) -> Self {
        self.capabilities.sort();
        self.capabilities.dedup();
        self
    }

    #[must_use]
    fn capabilities_set(&self) -> BTreeSet<BridgeCapability> {
        self.capabilities.iter().copied().collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiStartSpec {
    pub session_id: String,
    pub agent_id: String,
    pub tui_id: String,
    pub profile: AgentTuiLaunchProfile,
    pub project_dir: PathBuf,
    pub transcript_path: PathBuf,
    pub size: AgentTuiSize,
    pub prompt: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeConfigArgs {
    /// Explicit capability list. Omit the flag to enable every compiled capability.
    #[arg(long = "capability")]
    pub capabilities: Vec<BridgeCapability>,
    /// Override the control socket path.
    #[arg(long, value_name = "PATH")]
    pub socket_path: Option<PathBuf>,
    /// Port for the codex WebSocket capability.
    #[arg(long, env = CODEX_BRIDGE_PORT_ENV)]
    pub codex_port: Option<u16>,
    /// Explicit path to the `codex` binary.
    #[arg(long, value_name = "PATH")]
    pub codex_path: Option<PathBuf>,
}

impl BridgeConfigArgs {
    fn resolve(&self) -> Result<ResolvedBridgeConfig, CliError> {
        let persisted = read_bridge_config()?;
        resolve_bridge_config(merged_persisted_config(self, persisted))
    }
}

#[derive(Debug, Clone, Args)]
pub struct BridgeStartArgs {
    #[command(flatten)]
    pub config: BridgeConfigArgs,
    /// Detach from the terminal and run in the background.
    #[arg(long)]
    pub daemon: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeStopArgs {
    /// Print the final status as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeStatusArgs {
    /// Print a one-line summary instead of JSON.
    #[arg(long)]
    pub plain: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeInstallLaunchAgentArgs {
    #[command(flatten)]
    pub config: BridgeConfigArgs,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeReconfigureArgs {
    /// Enable one capability without restarting the bridge.
    #[arg(long = "enable")]
    pub enable: Vec<BridgeCapability>,
    /// Disable one capability without restarting the bridge.
    #[arg(long = "disable")]
    pub disable: Vec<BridgeCapability>,
    /// Force-disable `agent-tui` by stopping active TUI sessions first.
    #[arg(long)]
    pub force: bool,
    /// Print the updated bridge status as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeRemoveLaunchAgentArgs {
    /// Print confirmation as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum BridgeCommand {
    /// Start the unified host bridge.
    Start(BridgeStartArgs),
    /// Stop the running host bridge, if any.
    Stop(BridgeStopArgs),
    /// Print the current bridge status.
    Status(BridgeStatusArgs),
    /// Reconfigure the running bridge without restarting it.
    Reconfigure(BridgeReconfigureArgs),
    /// Install a per-user `LaunchAgent` that starts the bridge at login.
    InstallLaunchAgent(BridgeInstallLaunchAgentArgs),
    /// Remove the bridge `LaunchAgent` and clean up persisted state.
    RemoveLaunchAgent(BridgeRemoveLaunchAgentArgs),
}

impl Execute for BridgeCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Start(args) => args.execute(context),
            Self::Stop(args) => args.execute(context),
            Self::Status(args) => args.execute(context),
            Self::Reconfigure(args) => args.execute(context),
            Self::InstallLaunchAgent(args) => args.execute(context),
            Self::RemoveLaunchAgent(args) => args.execute(context),
        }
    }
}

/// Adopt the running daemon's root for the duration of this bridge
/// subcommand so its state writes target whatever daemon is actually
/// running (sandboxed managed, `harness daemon dev`, or a plain
/// `daemon serve`), regardless of which env vars the calling terminal
/// had set. See [`crate::daemon::discovery`] for the scan algorithm.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn adopt_daemon_root_for_bridge_command(command: &'static str) {
    match discovery::adopt_running_daemon_root() {
        AdoptionOutcome::AlreadyCoherent { root } => {
            tracing::debug!(
                command,
                root = %root.display(),
                "bridge: daemon root already coherent"
            );
        }
        AdoptionOutcome::Adopted { from, to } => {
            tracing::info!(
                command,
                from = %from.display(),
                to = %to.display(),
                "bridge: adopted running daemon root"
            );
        }
        AdoptionOutcome::NoRunningDaemon { default_root } => {
            tracing::warn!(
                command,
                default_root = %default_root.display(),
                "bridge: no running daemon found; bridge state will land at the default root"
            );
        }
    }
}

impl Execute for BridgeStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-start")?;
        adopt_daemon_root_for_bridge_command("bridge-start");
        cleanup_legacy_bridge_artifacts();
        let config = self.config.resolve()?;
        if matches_running_config(&config)? {
            if self.daemon {
                let report = status_report()?;
                print_status_plain(&report);
                return Ok(0);
            }
            return Err(CliErrorKind::workflow_io(
                "bridge is already running with the requested configuration; use `harness bridge stop` before running it in the foreground",
            )
            .into());
        }
        let _ = stop_bridge();
        if self.daemon {
            return start_detached(&config);
        }
        run_bridge_server(&config)
    }
}

impl Execute for BridgeStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_bridge_command("bridge-stop");
        cleanup_legacy_bridge_artifacts();
        let report = stop_bridge()?;
        if self.json {
            print_json(&report)?;
        } else {
            print_status_plain(&report);
        }
        Ok(0)
    }
}

impl Execute for BridgeStatusArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_bridge_command("bridge-status");
        let report = status_report()?;
        if self.plain {
            print_status_plain(&report);
        } else {
            print_json(&report)?;
        }
        Ok(0)
    }
}

impl Execute for BridgeInstallLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-install-launch-agent")?;
        adopt_daemon_root_for_bridge_command("bridge-install-launch-agent");
        cleanup_legacy_bridge_artifacts();
        let config = self.config.resolve()?;
        write_bridge_config(&config.persisted)?;
        let harness_binary = current_exe().map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
        })?;
        let plist = render_launch_agent_plist(&harness_binary);
        let plist_path = launch_agent_plist_path()?;
        if let Some(parent) = plist_path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliErrorKind::workflow_io(format!("create launch agent dir: {error}"))
            })?;
        }
        write_text(&plist_path, &plist)?;
        if cfg!(target_os = "macos") {
            best_effort_bootout(BRIDGE_LAUNCH_AGENT_LABEL);
            bootstrap_agent(&plist_path)?;
        }
        println!("installed {}", plist_path.display());
        Ok(0)
    }
}

impl Execute for BridgeReconfigureArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-reconfigure")?;
        adopt_daemon_root_for_bridge_command("bridge-reconfigure");
        cleanup_legacy_bridge_artifacts();
        let request = self.request()?;
        let report = BridgeClient::from_state_file()?.reconfigure(&request)?;
        if self.json {
            print_json(&report)?;
        } else {
            print_status_plain(&report);
        }
        Ok(0)
    }
}

impl Execute for BridgeRemoveLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-remove-launch-agent")?;
        adopt_daemon_root_for_bridge_command("bridge-remove-launch-agent");
        cleanup_legacy_bridge_artifacts();
        let plist_path = launch_agent_plist_path()?;
        let existed = plist_path.is_file();
        if existed && cfg!(target_os = "macos") {
            best_effort_bootout(BRIDGE_LAUNCH_AGENT_LABEL);
        }
        if existed {
            fs::remove_file(&plist_path).map_err(|error| {
                CliErrorKind::workflow_io(format!("remove bridge plist: {error}"))
            })?;
        }
        clear_bridge_state()?;
        if self.json {
            let json = json!({
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

impl BridgeReconfigureArgs {
    fn request(&self) -> Result<BridgeReconfigureSpec, CliError> {
        let request = BridgeReconfigureSpec {
            enable: self.enable.clone(),
            disable: self.disable.clone(),
            force: self.force,
        };
        request.validate()?;
        Ok(request)
    }
}

#[derive(Debug, Clone)]
struct ResolvedBridgeConfig {
    persisted: PersistedBridgeConfig,
    capabilities: BTreeSet<BridgeCapability>,
    socket_path: PathBuf,
    codex_port: u16,
    codex_binary: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeCodexMetadata {
    port: u16,
    binary_path: String,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    last_exit_status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeAgentTuiMetadata {
    active_sessions: usize,
}

#[derive(Debug, Clone)]
struct BridgeSnapshotContext {
    session_id: String,
    agent_id: String,
    tui_id: String,
    profile: AgentTuiLaunchProfile,
    project_dir: PathBuf,
    transcript_path: PathBuf,
}

impl BridgeSnapshotContext {
    fn borrowed(&self) -> AgentTuiSnapshotContext<'_> {
        AgentTuiSnapshotContext {
            session_id: &self.session_id,
            agent_id: &self.agent_id,
            tui_id: &self.tui_id,
            profile: &self.profile,
            project_dir: &self.project_dir,
            transcript_path: &self.transcript_path,
        }
    }
}

#[derive(Clone)]
struct BridgeActiveTui {
    process: Arc<AgentTuiProcess>,
    context: BridgeSnapshotContext,
    created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeEnvelope {
    token: String,
    request: BridgeRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum BridgeRequest {
    Status,
    Shutdown,
    Reconfigure {
        request: BridgeReconfigureSpec,
    },
    Capability {
        capability: String,
        action: String,
        #[serde(default)]
        payload: Value,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    payload: Option<Value>,
}

impl BridgeResponse {
    fn ok_payload<T: Serialize>(payload: &T) -> Result<Self, CliError> {
        let payload = serde_json::to_value(payload)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        Ok(Self {
            ok: true,
            code: None,
            message: None,
            details: None,
            payload: Some(payload),
        })
    }

    const fn empty_ok() -> Self {
        Self {
            ok: true,
            code: None,
            message: None,
            details: None,
            payload: None,
        }
    }

    fn error(error: &CliError) -> Self {
        Self {
            ok: false,
            code: Some(error.code().to_string()),
            message: Some(error.message()),
            details: error.details().map(str::to_owned),
            payload: None,
        }
    }
}

struct BridgeCodexProcess {
    child: Child,
    endpoint: String,
    metadata: BridgeCodexMetadata,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeReconfigureSpec {
    #[serde(default)]
    enable: Vec<BridgeCapability>,
    #[serde(default)]
    disable: Vec<BridgeCapability>,
    #[serde(default)]
    force: bool,
}

impl BridgeReconfigureSpec {
    fn validate(&self) -> Result<(), CliError> {
        if self.enable.is_empty() && self.disable.is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure requires at least one --enable or --disable flag",
            )
            .into());
        }
        let enable: BTreeSet<_> = self.enable.iter().copied().collect();
        if enable.len() != self.enable.len() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure listed the same capability more than once in --enable",
            )
            .into());
        }
        let disable: BTreeSet<_> = self.disable.iter().copied().collect();
        if disable.len() != self.disable.len() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure listed the same capability more than once in --disable",
            )
            .into());
        }
        if let Some(contradiction) = enable.intersection(&disable).next().copied() {
            return Err(CliErrorKind::workflow_parse(format!(
                "bridge reconfigure cannot enable and disable '{}' in one request",
                contradiction.name()
            ))
            .into());
        }
        Ok(())
    }

    #[must_use]
    fn enable_set(&self) -> BTreeSet<BridgeCapability> {
        self.enable.iter().copied().collect()
    }

    #[must_use]
    fn disable_set(&self) -> BTreeSet<BridgeCapability> {
        self.disable.iter().copied().collect()
    }

    fn from_names(enable: &[String], disable: &[String], force: bool) -> Result<Self, CliError> {
        let enable = enable
            .iter()
            .map(|name| {
                BridgeCapability::from_name(name).ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!("unsupported bridge capability '{name}'"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let disable = disable
            .iter()
            .map(|name| {
                BridgeCapability::from_name(name).ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!("unsupported bridge capability '{name}'"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let request = Self {
            enable,
            disable,
            force,
        };
        request.validate()?;
        Ok(request)
    }
}

struct BridgeServer {
    token: String,
    socket_path: PathBuf,
    pid: u32,
    started_at: String,
    token_path: String,
    desired_config: Mutex<PersistedBridgeConfig>,
    capabilities: Mutex<BTreeMap<String, HostBridgeCapabilityManifest>>,
    active_tuis: Mutex<BTreeMap<String, BridgeActiveTui>>,
    codex: Mutex<Option<BridgeCodexProcess>>,
    shutdown: AtomicBool,
}

impl BridgeServer {
    fn new(
        token: String,
        socket_path: PathBuf,
        desired_config: PersistedBridgeConfig,
        capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
    ) -> Self {
        Self {
            token,
            socket_path,
            pid: process_id(),
            started_at: utc_now(),
            token_path: state::auth_token_path().display().to_string(),
            desired_config: Mutex::new(desired_config),
            capabilities: Mutex::new(capabilities),
            active_tuis: Mutex::new(BTreeMap::new()),
            codex: Mutex::new(None),
            shutdown: AtomicBool::new(false),
        }
    }

    fn state(&self) -> Result<BridgeState, CliError> {
        Ok(BridgeState {
            socket_path: self.socket_path.display().to_string(),
            pid: self.pid,
            started_at: self.started_at.clone(),
            token_path: self.token_path.clone(),
            capabilities: self.capabilities()?.clone(),
        })
    }

    fn persist_state(&self) -> Result<(), CliError> {
        write_bridge_state(&self.state()?)
    }

    fn status_report(&self) -> Result<BridgeStatusReport, CliError> {
        Ok(BridgeStatusReport {
            running: true,
            socket_path: Some(self.socket_path.display().to_string()),
            pid: Some(self.pid),
            started_at: Some(self.started_at.clone()),
            uptime_seconds: uptime_from_started_at(&self.started_at),
            capabilities: self.capabilities()?.clone(),
        })
    }

    fn handle(self: &Arc<Self>, envelope: BridgeEnvelope) -> BridgeResponse {
        if envelope.token != self.token {
            let error = CliError::from(CliErrorKind::workflow_io("bridge token mismatch"));
            return BridgeResponse::error(&error);
        }
        match self.handle_authorized(envelope.request) {
            Ok(response) => response,
            Err(error) => BridgeResponse::error(&error),
        }
    }

    fn handle_authorized(
        self: &Arc<Self>,
        request: BridgeRequest,
    ) -> Result<BridgeResponse, CliError> {
        match request {
            BridgeRequest::Status => BridgeResponse::ok_payload(&self.status_report()?),
            BridgeRequest::Shutdown => {
                self.shutdown.store(true, Ordering::SeqCst);
                Ok(BridgeResponse::empty_ok())
            }
            BridgeRequest::Reconfigure { request } => {
                let report = self.reconfigure(&request)?;
                BridgeResponse::ok_payload(&report)
            }
            BridgeRequest::Capability {
                capability,
                action,
                payload,
            } => self.handle_capability(&capability, &action, payload),
        }
    }

    fn reconfigure(
        self: &Arc<Self>,
        request: &BridgeReconfigureSpec,
    ) -> Result<BridgeStatusReport, CliError> {
        request.validate()?;

        let enable = request.enable_set();
        let disable = request.disable_set();

        let current_desired = self.desired_config()?.clone();
        let mut next_desired = current_desired.clone();
        let mut next_capabilities = current_desired.capabilities_set();
        for capability in &enable {
            next_capabilities.insert(*capability);
        }
        for capability in &disable {
            next_capabilities.remove(capability);
        }
        next_desired.capabilities = next_capabilities.into_iter().collect();

        let resolved_next = resolve_bridge_config(next_desired.clone())?;
        self.apply_capability_changes(&enable, &disable, request.force, &resolved_next)?;

        *self.desired_config()? = next_desired.clone();
        write_bridge_config(&next_desired)?;
        Self::sync_launch_agent_if_installed()?;
        self.status_report()
    }

    fn apply_capability_changes(
        self: &Arc<Self>,
        enable: &BTreeSet<BridgeCapability>,
        disable: &BTreeSet<BridgeCapability>,
        force: bool,
        resolved_next: &ResolvedBridgeConfig,
    ) -> Result<(), CliError> {
        let current_enabled: BTreeSet<_> = self
            .capabilities()?
            .keys()
            .filter_map(|name| BridgeCapability::from_name(name))
            .collect();

        for capability in disable {
            if current_enabled.contains(capability) {
                self.pre_disable_check(*capability, force)?;
            }
        }

        for capability in enable {
            if self.should_enable_capability(*capability, &current_enabled)? {
                self.enable_capability(*capability, resolved_next)?;
            }
        }
        for capability in disable {
            if current_enabled.contains(capability) {
                self.disable_capability(*capability, force)?;
            }
        }
        Ok(())
    }

    fn handle_capability(
        &self,
        capability: &str,
        action: &str,
        payload: Value,
    ) -> Result<BridgeResponse, CliError> {
        match capability {
            BRIDGE_CAPABILITY_AGENT_TUI => self.handle_agent_tui(action, payload),
            BRIDGE_CAPABILITY_CODEX => Err(CliErrorKind::workflow_parse(format!(
                "bridge capability '{capability}' does not support '{action}' operations"
            ))
            .into()),
            _ => Err(CliErrorKind::workflow_parse(format!(
                "unsupported bridge capability '{capability}'"
            ))
            .into()),
        }
    }

    fn handle_agent_tui(&self, action: &str, payload: Value) -> Result<BridgeResponse, CliError> {
        match action {
            "start" => {
                let spec: AgentTuiStartSpec = parse_bridge_payload(payload)?;
                let snapshot = self.start_agent_tui(spec)?;
                BridgeResponse::ok_payload(&snapshot)
            }
            "get" => {
                let request: BridgeGetRequest = parse_bridge_payload(payload)?;
                let snapshot = self.get_agent_tui(&request.tui_id)?;
                BridgeResponse::ok_payload(&snapshot)
            }
            "input" => {
                let request: BridgeInputRequest = parse_bridge_payload(payload)?;
                let process = self.active_tui(&request.tui_id)?.process;
                process.send_input(&request.request.input)?;
                let snapshot = self.get_agent_tui(&request.tui_id)?;
                BridgeResponse::ok_payload(&snapshot)
            }
            "resize" => {
                let request: BridgeResizeRequest = parse_bridge_payload(payload)?;
                let process = self.active_tui(&request.tui_id)?.process;
                process.resize(request.request.size()?)?;
                let snapshot = self.get_agent_tui(&request.tui_id)?;
                BridgeResponse::ok_payload(&snapshot)
            }
            "stop" => {
                let request: BridgeGetRequest = parse_bridge_payload(payload)?;
                let snapshot = self.stop_agent_tui(&request.tui_id)?;
                BridgeResponse::ok_payload(&snapshot)
            }
            _ => Err(CliErrorKind::workflow_parse(format!(
                "unsupported agent-tui bridge action '{action}'"
            ))
            .into()),
        }
    }

    fn start_agent_tui(&self, spec: AgentTuiStartSpec) -> Result<AgentTuiSnapshot, CliError> {
        if !self
            .capabilities()?
            .contains_key(BRIDGE_CAPABILITY_AGENT_TUI)
        {
            return Err(CliErrorKind::sandbox_feature_disabled(
                BridgeCapability::AgentTui.sandbox_feature(),
            )
            .into());
        }
        if self.active_tuis()?.contains_key(&spec.tui_id) {
            return Err(CliErrorKind::workflow_io(format!(
                "agent TUI '{}' is already active in host bridge",
                spec.tui_id
            ))
            .into());
        }
        let process = spawn_agent_tui_process(
            &spec.session_id,
            &spec.agent_id,
            &spec.tui_id,
            spec.profile.clone(),
            &spec.project_dir,
            spec.size,
        )?;
        if let Some(prompt) = spec.prompt.as_deref().filter(|prompt| !prompt.is_empty()) {
            send_initial_prompt(&process, prompt)?;
        }
        let process = Arc::new(process);
        let context = BridgeSnapshotContext {
            session_id: spec.session_id,
            agent_id: spec.agent_id,
            tui_id: spec.tui_id.clone(),
            profile: spec.profile,
            project_dir: spec.project_dir,
            transcript_path: spec.transcript_path,
        };
        let snapshot =
            snapshot_from_process(&context.borrowed(), &process, AgentTuiStatus::Running)?;
        self.active_tuis()?.insert(
            spec.tui_id,
            BridgeActiveTui {
                process,
                context,
                created_at: snapshot.created_at.clone(),
            },
        );
        self.update_agent_tui_metadata()?;
        Ok(snapshot)
    }

    fn get_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tui(tui_id)?;
        let mut status = AgentTuiStatus::Running;
        let mut exit_code = None;
        let mut signal = None;
        if let Some(exit_status) = active.process.try_wait()? {
            status = AgentTuiStatus::Exited;
            exit_code = Some(exit_status.exit_code());
            signal = exit_status.signal().map(ToString::to_string);
            let _ = self.active_tuis()?.remove(tui_id);
            self.update_agent_tui_metadata()?;
        }
        let mut snapshot =
            snapshot_from_process(&active.context.borrowed(), &active.process, status)?;
        snapshot.created_at = active.created_at;
        snapshot.exit_code = exit_code;
        snapshot.signal = signal;
        Ok(snapshot)
    }

    fn stop_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tuis()?.remove(tui_id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "agent TUI '{tui_id}' is not active in host bridge"
            ))
        })?;
        active.process.kill()?;
        let _ = active.process.wait_timeout(Duration::from_millis(500))?;
        let mut snapshot = snapshot_from_process(
            &active.context.borrowed(),
            &active.process,
            AgentTuiStatus::Stopped,
        )?;
        snapshot.created_at = active.created_at;
        self.update_agent_tui_metadata()?;
        Ok(snapshot)
    }

    fn active_tui(&self, tui_id: &str) -> Result<BridgeActiveTui, CliError> {
        self.active_tuis()?.get(tui_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "agent TUI '{tui_id}' is not active in host bridge"
            ))
            .into()
        })
    }

    fn update_agent_tui_metadata(&self) -> Result<(), CliError> {
        let active_sessions = self.active_tuis()?.len();
        let metadata = BridgeAgentTuiMetadata { active_sessions };
        let manifest = HostBridgeCapabilityManifest {
            enabled: true,
            healthy: true,
            transport: "unix".to_string(),
            endpoint: Some(self.socket_path.display().to_string()),
            metadata: stringify_metadata_map(&metadata),
        };
        self.capabilities()?
            .insert(BRIDGE_CAPABILITY_AGENT_TUI.to_string(), manifest);
        self.persist_state()
    }

    fn set_codex_process(&self, process: BridgeCodexProcess) -> Result<(), CliError> {
        let endpoint = process.endpoint.clone();
        let metadata = stringify_metadata_map(&process.metadata);
        self.capabilities()?.insert(
            BRIDGE_CAPABILITY_CODEX.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "websocket".to_string(),
                endpoint: Some(endpoint),
                metadata,
            },
        );
        *self.codex()? = Some(process);
        self.persist_state()
    }

    fn mark_codex_unhealthy(&self, last_exit_status: String) -> Result<(), CliError> {
        let mut capabilities = self.capabilities()?;
        let Some(codex) = capabilities.get_mut(BRIDGE_CAPABILITY_CODEX) else {
            return Ok(());
        };
        codex.healthy = false;
        codex
            .metadata
            .insert("last_exit_status".to_string(), last_exit_status);
        drop(capabilities);
        self.persist_state()
    }

    fn enable_capability(
        self: &Arc<Self>,
        capability: BridgeCapability,
        config: &ResolvedBridgeConfig,
    ) -> Result<(), CliError> {
        match capability {
            BridgeCapability::Codex => self.enable_codex(config),
            BridgeCapability::AgentTui => self.enable_agent_tui(),
        }
    }

    fn enable_agent_tui(&self) -> Result<(), CliError> {
        self.update_agent_tui_metadata()
    }

    fn enable_codex(self: &Arc<Self>, config: &ResolvedBridgeConfig) -> Result<(), CliError> {
        let binary = config.codex_binary.as_ref().ok_or_else(|| {
            CliErrorKind::workflow_io("codex capability requires a resolved codex binary")
        })?;
        let _ = self.disable_codex();
        let process = spawn_codex_process(binary, config.codex_port)?;
        self.set_codex_process(process)?;
        spawn_codex_monitor(Arc::clone(self));
        Ok(())
    }

    fn pre_disable_check(&self, capability: BridgeCapability, force: bool) -> Result<(), CliError> {
        match capability {
            BridgeCapability::Codex => Ok(()),
            BridgeCapability::AgentTui => self.ensure_agent_tui_can_disable(force),
        }
    }

    fn disable_capability(
        &self,
        capability: BridgeCapability,
        force: bool,
    ) -> Result<(), CliError> {
        match capability {
            BridgeCapability::Codex => self.disable_codex(),
            BridgeCapability::AgentTui => self.disable_agent_tui(force),
        }
    }

    fn disable_codex(&self) -> Result<(), CliError> {
        if let Ok(mut codex) = self.codex.lock()
            && let Some(process) = codex.as_mut()
        {
            let _ = process.child.kill();
            let _ = process.child.wait();
            codex.take();
        }
        self.capabilities()?.remove(BRIDGE_CAPABILITY_CODEX);
        self.persist_state()
    }

    fn disable_agent_tui(&self, force: bool) -> Result<(), CliError> {
        self.ensure_agent_tui_can_disable(force)?;
        if force {
            let tui_ids: Vec<String> = self.active_tuis()?.keys().cloned().collect();
            for tui_id in tui_ids {
                let _ = self.stop_agent_tui(&tui_id)?;
            }
        }
        self.capabilities()?.remove(BRIDGE_CAPABILITY_AGENT_TUI);
        self.persist_state()
    }

    fn ensure_agent_tui_can_disable(&self, force: bool) -> Result<(), CliError> {
        let active_sessions = self.active_tuis()?.len();
        if active_sessions > 0 && !force {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "agent-tui capability has {active_sessions} active session(s); rerun with --force to stop them first"
            ))
            .into());
        }
        Ok(())
    }

    fn should_enable_capability(
        &self,
        capability: BridgeCapability,
        current_enabled: &BTreeSet<BridgeCapability>,
    ) -> Result<bool, CliError> {
        if !current_enabled.contains(&capability) {
            return Ok(true);
        }
        match capability {
            BridgeCapability::Codex => self.codex_requires_restart(),
            BridgeCapability::AgentTui => Ok(false),
        }
    }

    fn codex_requires_restart(&self) -> Result<bool, CliError> {
        if self
            .capabilities()?
            .get(BRIDGE_CAPABILITY_CODEX)
            .is_some_and(|manifest| !manifest.healthy)
        {
            return Ok(true);
        }
        let mut codex = self.codex()?;
        let Some(process) = codex.as_mut() else {
            return Ok(true);
        };
        Ok(process.child.try_wait()?.is_some())
    }

    fn sync_launch_agent_if_installed() -> Result<(), CliError> {
        let plist_path = launch_agent_plist_path()?;
        if !plist_path.is_file() {
            return Ok(());
        }
        let harness_binary = current_exe().map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
        })?;
        write_text(&plist_path, &render_launch_agent_plist(&harness_binary))
    }

    fn shutdown_requested(&self) -> bool {
        self.shutdown.load(Ordering::SeqCst)
    }

    fn cleanup(&self) {
        if let Ok(mut active) = self.active_tuis.lock() {
            for (_, entry) in active.iter() {
                let _ = entry.process.kill();
            }
            active.clear();
        }
        if let Ok(mut codex) = self.codex.lock()
            && let Some(process) = codex.as_mut()
        {
            let _ = process.child.kill();
            let _ = process.child.wait();
            codex.take();
        }
    }

    fn capabilities(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, HostBridgeCapabilityManifest>>, CliError> {
        self.capabilities.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge capabilities lock poisoned: {error}")).into()
        })
    }

    fn active_tuis(&self) -> Result<MutexGuard<'_, BTreeMap<String, BridgeActiveTui>>, CliError> {
        self.active_tuis.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge active map poisoned: {error}")).into()
        })
    }

    fn codex(&self) -> Result<MutexGuard<'_, Option<BridgeCodexProcess>>, CliError> {
        self.codex.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge codex lock poisoned: {error}")).into()
        })
    }

    fn desired_config(&self) -> Result<MutexGuard<'_, PersistedBridgeConfig>, CliError> {
        self.desired_config.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge desired config lock poisoned: {error}"))
                .into()
        })
    }
}

#[derive(Debug, Clone)]
pub struct BridgeClient {
    socket_path: PathBuf,
    token: String,
}

impl BridgeClient {
    /// Build a bridge client directly from one persisted bridge state record.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge auth token cannot be loaded.
    pub fn from_state(state: &BridgeState) -> Result<Self, CliError> {
        let token = fs::read_to_string(&state.token_path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "read bridge token {}: {error}",
                    state.token_path
                ))
            })?
            .trim()
            .to_string();
        Ok(Self {
            socket_path: PathBuf::from(&state.socket_path),
            token,
        })
    }

    /// Build a bridge client from the persisted running bridge state.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge is unavailable or the auth token
    /// cannot be loaded.
    pub fn from_state_file() -> Result<Self, CliError> {
        let state = resolve_running_bridge(LivenessMode::HostAuthoritative)?
            .map(|running| running.state)
            .ok_or_else(|| CliErrorKind::workflow_io("bridge is not running"))?;
        Self::from_state(&state)
    }

    /// Build a bridge client for one required capability.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge is unavailable, the capability is
    /// not enabled, or the auth token cannot be loaded.
    pub fn for_capability(capability: BridgeCapability) -> Result<Self, CliError> {
        let running = resolve_running_bridge(LivenessMode::HostAuthoritative)?
            .ok_or_else(|| CliErrorKind::sandbox_feature_disabled(capability.sandbox_feature()))?;
        if !running.report.capabilities.contains_key(capability.name()) {
            return Err(
                CliErrorKind::sandbox_feature_disabled(capability.sandbox_feature()).into(),
            );
        }
        Self::from_state(&running.state)
    }

    fn send(&self, request: BridgeRequest) -> Result<BridgeResponse, CliError> {
        let envelope = BridgeEnvelope {
            token: self.token.clone(),
            request,
        };
        let payload = serde_json::to_string(&envelope)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        let mut stream = UnixStream::connect(&self.socket_path).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "connect bridge socket {}: {error}",
                self.socket_path.display()
            ))
        })?;
        stream
            .write_all(payload.as_bytes())
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .map_err(|error| CliErrorKind::workflow_io(format!("write bridge request: {error}")))?;
        let mut line = String::new();
        BufReader::new(stream)
            .read_line(&mut line)
            .map_err(|error| CliErrorKind::workflow_io(format!("read bridge response: {error}")))?;
        serde_json::from_str(&line).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse bridge response: {error}")).into()
        })
    }

    fn typed_capability_request<T: DeserializeOwned, P: Serialize>(
        &self,
        capability: BridgeCapability,
        action: &str,
        payload: &P,
    ) -> Result<T, CliError> {
        let payload = serde_json::to_value(payload)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        let response = self.send(BridgeRequest::Capability {
            capability: capability.name().to_string(),
            action: action.to_string(),
            payload,
        })?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        let payload = response
            .payload
            .ok_or_else(|| CliErrorKind::workflow_io("bridge response omitted payload"))?;
        serde_json::from_value(payload).map_err(|error| {
            CliErrorKind::workflow_parse(format!("decode bridge payload: {error}")).into()
        })
    }

    /// Ask the running bridge to shut down.
    ///
    /// # Errors
    /// Returns [`CliError`] when the shutdown request fails or the bridge
    /// returns an error response.
    pub fn shutdown(&self) -> Result<(), CliError> {
        let response = self.send(BridgeRequest::Shutdown)?;
        if response.ok {
            return Ok(());
        }
        Err(bridge_response_error(response))
    }

    /// Ask the running bridge for its current status report.
    ///
    /// # Errors
    /// Returns [`CliError`] when the request fails or the bridge returns an
    /// error response.
    pub fn status(&self) -> Result<BridgeStatusReport, CliError> {
        let response = self.send(BridgeRequest::Status)?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        let payload = response
            .payload
            .ok_or_else(|| CliErrorKind::workflow_io("bridge response omitted payload"))?;
        parse_bridge_payload(payload)
    }

    fn reconfigure(&self, request: &BridgeReconfigureSpec) -> Result<BridgeStatusReport, CliError> {
        let response = self.send(BridgeRequest::Reconfigure {
            request: request.clone(),
        })?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        let payload = response
            .payload
            .ok_or_else(|| CliErrorKind::workflow_io("bridge response omitted payload"))?;
        parse_bridge_payload(payload)
    }

    /// Start one bridge-managed agent TUI session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be encoded or decoded.
    pub fn agent_tui_start(&self, spec: &AgentTuiStartSpec) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(BridgeCapability::AgentTui, "start", spec)
    }

    /// Load the latest snapshot for one bridge-managed agent TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_get(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "get",
            &BridgeGetRequest {
                tui_id: tui_id.to_string(),
            },
        )
    }

    /// Send keyboard-like input to one bridge-managed agent TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "input",
            &BridgeInputRequest {
                tui_id: tui_id.to_string(),
                request: request.clone(),
            },
        )
    }

    /// Resize one bridge-managed agent TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_resize(
        &self,
        tui_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "resize",
            &BridgeResizeRequest {
                tui_id: tui_id.to_string(),
                request: *request,
            },
        )
    }

    /// Stop one bridge-managed agent TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_stop(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "stop",
            &BridgeGetRequest {
                tui_id: tui_id.to_string(),
            },
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeGetRequest {
    tui_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeInputRequest {
    tui_id: String,
    request: AgentTuiInputRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BridgeResizeRequest {
    tui_id: String,
    request: AgentTuiResizeRequest,
}

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

fn bridge_socket_path_for_root(daemon_root: &Path) -> PathBuf {
    let preferred = daemon_root.join(DEFAULT_BRIDGE_SOCKET_NAME);
    if unix_socket_path_fits(&preferred) {
        return preferred;
    }
    fallback_bridge_socket_path(daemon_root)
}

fn unix_socket_path_fits(path: &Path) -> bool {
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
fn group_container_root(daemon_root: &Path) -> Option<PathBuf> {
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

fn read_bridge_config() -> Result<Option<PersistedBridgeConfig>, CliError> {
    if !bridge_config_path().is_file() {
        return Ok(None);
    }
    read_json_typed(&bridge_config_path())
        .map(|config: PersistedBridgeConfig| Some(config.normalized()))
}

fn write_bridge_state(state: &BridgeState) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
    write_json_pretty(&bridge_state_path(), state)
}

fn write_bridge_config(config: &PersistedBridgeConfig) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
    write_json_pretty(&bridge_config_path(), &config.clone().normalized())
}

fn clear_bridge_state() -> Result<(), CliError> {
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
enum BridgeProof {
    Lock,
    Rpc,
    Pid,
}

#[derive(Debug, Clone)]
struct ResolvedRunningBridge {
    state: BridgeState,
    report: BridgeStatusReport,
    proof: BridgeProof,
    client: Option<BridgeClient>,
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
    matches!(mode, LivenessMode::HostAuthoritative) && !super::service::sandboxed_from_env()
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

fn resolve_running_bridge(mode: LivenessMode) -> Result<Option<ResolvedRunningBridge>, CliError> {
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
    if super::service::sandboxed_from_env() {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShutdownRequestOutcome {
    Sent,
    MissingClient,
    SendFailed,
}

fn send_bridge_shutdown_request(client: Option<&BridgeClient>) -> ShutdownRequestOutcome {
    match client {
        Some(client) if client.shutdown().is_ok() => ShutdownRequestOutcome::Sent,
        Some(_) => ShutdownRequestOutcome::SendFailed,
        None => ShutdownRequestOutcome::MissingClient,
    }
}

fn bridge_shutdown_warning(outcome: ShutdownRequestOutcome) -> Option<&'static str> {
    match outcome {
        ShutdownRequestOutcome::Sent => None,
        ShutdownRequestOutcome::MissingClient => {
            Some("bridge stop: missing bridge client, skipping graceful shutdown request")
        }
        ShutdownRequestOutcome::SendFailed => Some("bridge stop: graceful shutdown request failed"),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion in a leaf logging helper"
)]
fn log_bridge_shutdown_warning(message: &'static str) {
    tracing::warn!("{message}");
}

fn request_bridge_shutdown(running: &ResolvedRunningBridge) {
    if let Some(message) =
        bridge_shutdown_warning(send_bridge_shutdown_request(running.client.as_ref()))
    {
        log_bridge_shutdown_warning(message);
    }
}

#[must_use]
fn stopped_bridge_report(running: &ResolvedRunningBridge) -> BridgeStatusReport {
    BridgeStatusReport {
        running: false,
        socket_path: Some(running.state.socket_path.clone()),
        pid: Some(running.state.pid),
        started_at: Some(running.state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&running.state.started_at),
        capabilities: running.report.capabilities.clone(),
    }
}

/// Stop the running bridge and clean up its persisted state.
///
/// # Errors
/// Returns [`CliError`] when the bridge cannot be contacted or its state files
/// cannot be removed.
pub fn stop_bridge() -> Result<BridgeStatusReport, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)? else {
        clear_bridge_state()?;
        return Ok(BridgeStatusReport::not_running());
    };
    request_bridge_shutdown(&running);
    wait_until_bridge_dead(&running, STOP_GRACE_PERIOD)?;
    clear_bridge_state()?;
    Ok(stopped_bridge_report(&running))
}

/// Apply a capability reconfiguration to the running bridge.
///
/// # Errors
/// Returns [`CliError`] when the reconfiguration request is invalid, the
/// running bridge state cannot be loaded, or the bridge rejects the request.
pub fn reconfigure_bridge(
    enable: &[String],
    disable: &[String],
    force: bool,
) -> Result<BridgeStatusReport, CliError> {
    let request = BridgeReconfigureSpec::from_names(enable, disable, force)?;
    BridgeClient::from_state_file()?.reconfigure(&request)
}

/// Spawn the daemon manifest watcher that republishes bridge state changes.
#[must_use]
pub fn spawn_manifest_watcher() -> JoinHandle<()> {
    tokio::spawn(async move {
        run_manifest_watcher().await;
    })
}

async fn run_manifest_watcher() {
    let Some((_daemon_root, _watcher, mut event_rx)) = manifest_watcher_parts() else {
        return;
    };
    apply_bridge_state_to_manifest();
    drive_manifest_watcher(&mut event_rx).await;
}

enum ManifestWatcherSetupError {
    RootUnavailable,
    WatcherUnavailable,
}

#[expect(
    clippy::cognitive_complexity,
    reason = "warning dispatch branches are small and explicit here"
)]
fn manifest_watcher_parts() -> Option<(
    PathBuf,
    RecommendedWatcher,
    mpsc::Receiver<notify::Result<notify::Event>>,
)> {
    match setup_manifest_watcher() {
        Ok(parts) => Some(parts),
        Err(ManifestWatcherSetupError::RootUnavailable) => {
            tracing::warn!("bridge watcher: unable to ensure daemon root");
            None
        }
        Err(ManifestWatcherSetupError::WatcherUnavailable) => {
            tracing::warn!("bridge watcher: failed to build filesystem watcher");
            None
        }
    }
}

fn setup_manifest_watcher() -> Result<
    (
        PathBuf,
        RecommendedWatcher,
        mpsc::Receiver<notify::Result<notify::Event>>,
    ),
    ManifestWatcherSetupError,
> {
    let daemon_root = ensure_watcher_root().ok_or(ManifestWatcherSetupError::RootUnavailable)?;
    let (event_tx, event_rx) = mpsc::channel::<notify::Result<notify::Event>>(32);
    let watcher = build_manifest_watcher(&daemon_root, event_tx)
        .ok_or(ManifestWatcherSetupError::WatcherUnavailable)?;
    Ok((daemon_root, watcher, event_rx))
}

async fn drive_manifest_watcher(event_rx: &mut mpsc::Receiver<notify::Result<notify::Event>>) {
    while event_rx.recv().await.is_some() {
        sleep(WATCH_DEBOUNCE).await;
        while event_rx.try_recv().is_ok() {}
        apply_bridge_state_to_manifest();
    }
}

fn ensure_watcher_root() -> Option<PathBuf> {
    state::ensure_daemon_dirs().ok()?;
    Some(state::daemon_root())
}

fn build_manifest_watcher(
    daemon_root: &Path,
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> Option<RecommendedWatcher> {
    create_manifest_watcher(event_tx).and_then(|watcher| watch_bridge_root(watcher, daemon_root))
}

/// Pure decision: given the current on-disk manifest return the manifest that
/// should be published, or `None` if the host-bridge state is unchanged.
///
/// Extracted as a pure function so the "did the watcher correctly decide to
/// publish an update?" branch can be unit-tested without standing up a real
/// daemon.
pub(crate) fn compute_bridge_manifest_update(
    current: &state::DaemonManifest,
) -> Option<state::DaemonManifest> {
    let host_bridge = host_bridge_manifest().ok()?;
    if current.host_bridge == host_bridge {
        return None;
    }
    Some(state::DaemonManifest {
        host_bridge,
        ..current.clone()
    })
}

fn apply_bridge_state_to_manifest() {
    let Some(current) = state::load_manifest().ok().flatten() else {
        return;
    };
    let Some(next) = compute_bridge_manifest_update(&current) else {
        return;
    };
    publish_bridge_manifest_update(&next);
}

fn write_bridge_manifest_update(manifest: &state::DaemonManifest) -> Result<(), CliError> {
    state::write_manifest(manifest).map(drop)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "single warning branch kept local to manifest publish failures"
)]
fn publish_bridge_manifest_update(manifest: &state::DaemonManifest) {
    if let Err(error) = write_bridge_manifest_update(manifest) {
        tracing::warn!(%error, "bridge watcher: failed to publish manifest update");
    }
}

fn create_manifest_watcher(
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> Option<RecommendedWatcher> {
    RecommendedWatcher::new(
        move |result| {
            let _ = event_tx.blocking_send(result);
        },
        notify::Config::default(),
    )
    .ok()
}

fn watch_bridge_root(
    mut watcher: RecommendedWatcher,
    daemon_root: &Path,
) -> Option<RecommendedWatcher> {
    watcher
        .watch(daemon_root, RecursiveMode::NonRecursive)
        .ok()?;
    Some(watcher)
}

fn matches_running_config(config: &ResolvedBridgeConfig) -> Result<bool, CliError> {
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
fn run_bridge_server(config: &ResolvedBridgeConfig) -> Result<i32, CliError> {
    state::ensure_daemon_dirs()?;
    // Acquire the bridge lock BEFORE unlinking the socket so a racing second
    // `harness bridge start` cannot unlink the live socket of the first
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
    fs::set_permissions(&config.socket_path, Permissions::from_mode(0o600)).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "set bridge socket permissions {}: {error}",
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
    write_bridge_config(&config.persisted)?;
    if config.capabilities.contains(&BridgeCapability::Codex) {
        server.enable_codex(config)?;
    }
    server.persist_state()?;

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle_stream(&server, stream)?,
            Err(error) => {
                return Err(CliErrorKind::workflow_io(format!(
                    "accept bridge connection: {error}"
                ))
                .into());
            }
        }
        if server.shutdown_requested() {
            break;
        }
    }
    server.cleanup();
    clear_bridge_state()?;
    socket_guard.disarm();
    Ok(0)
}

/// RAII guard that unlinks the bridge unix socket file on drop, unless
/// `disarm()` is called. Installed by `run_bridge_server` right after
/// `bind()` so any error return, panic, or unexpected exit still cleans
/// up the socket file (signal-delivered `SIGKILL` remains a leak vector
/// and is handled by `mise run clean:stale`).
struct BridgeSocketGuard {
    path: PathBuf,
    armed: bool,
}

impl BridgeSocketGuard {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
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

fn spawn_codex_process(binary: &Path, port: u16) -> Result<BridgeCodexProcess, CliError> {
    let listen_address = format!("ws://127.0.0.1:{port}");
    let child = Command::new(binary)
        .args(["app-server", "--listen", &listen_address])
        .stdin(Stdio::null())
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn codex app-server: {error}")))?;
    let version = detect_codex_version(binary);
    Ok(BridgeCodexProcess {
        child,
        endpoint: listen_address,
        metadata: BridgeCodexMetadata {
            port,
            binary_path: binary.display().to_string(),
            version,
            last_exit_status: None,
        },
    })
}

fn spawn_codex_monitor(server: Arc<BridgeServer>) {
    thread::spawn(move || {
        loop {
            if server.shutdown_requested() {
                return;
            }
            let result = {
                let Ok(mut codex) = server.codex.lock() else {
                    return;
                };
                let Some(process) = codex.as_mut() else {
                    return;
                };
                process
                    .child
                    .try_wait()
                    .ok()
                    .flatten()
                    .map(|status| status.to_string())
            };
            if let Some(status) = result {
                let _ = server.mark_codex_unhealthy(status);
                return;
            }
            thread::sleep(Duration::from_millis(250));
        }
    });
}

fn initial_capabilities(
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
    if config.capabilities.contains(&BridgeCapability::Codex)
        && let Some(binary) = config.codex_binary.as_ref()
    {
        capabilities.insert(
            BRIDGE_CAPABILITY_CODEX.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: false,
                transport: "websocket".to_string(),
                endpoint: Some(format!("ws://127.0.0.1:{}", config.codex_port)),
                metadata: stringify_metadata_map(&BridgeCodexMetadata {
                    port: config.codex_port,
                    binary_path: binary.display().to_string(),
                    version: detect_codex_version(binary),
                    last_exit_status: None,
                }),
            },
        );
    }
    capabilities
}

fn handle_stream(server: &Arc<BridgeServer>, stream: UnixStream) -> Result<(), CliError> {
    let mut line = String::new();
    BufReader::new(
        stream
            .try_clone()
            .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge stream: {error}")))?,
    )
    .read_line(&mut line)
    .map_err(|error| CliErrorKind::workflow_io(format!("read bridge request: {error}")))?;
    let response = match serde_json::from_str::<BridgeEnvelope>(&line) {
        Ok(envelope) => server.handle(envelope),
        Err(error) => {
            let error = CliError::from(CliErrorKind::workflow_parse(format!(
                "parse bridge request: {error}"
            )));
            BridgeResponse::error(&error)
        }
    };
    let payload = serde_json::to_string(&response)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    let mut writer = stream;
    writer
        .write_all(payload.as_bytes())
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("write bridge response: {error}")).into()
        })
}

fn start_detached(config: &ResolvedBridgeConfig) -> Result<i32, CliError> {
    let harness = current_exe().map_err(|error| {
        CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
    })?;
    state::ensure_daemon_dirs()?;
    let stdout_path = state::daemon_root().join("bridge.stdout.log");
    let stderr_path = state::daemon_root().join("bridge.stderr.log");
    let stdout = File::create(&stdout_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("create {}: {error}", stdout_path.display()))
    })?;
    let stderr = File::create(&stderr_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("create {}: {error}", stderr_path.display()))
    })?;
    let mut command = Command::new(&harness);
    write_bridge_config(&config.persisted)?;
    command.arg("bridge").arg("start");
    let mut child = command
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn bridge: {error}")))?;
    wait_for_detached_bridge_start(&mut child, config, &stdout_path, &stderr_path)?;
    println!("bridge started in background (pid {})", child.id());
    Ok(0)
}

fn wait_for_detached_bridge_start(
    child: &mut Child,
    config: &ResolvedBridgeConfig,
    stdout_path: &Path,
    stderr_path: &Path,
) -> Result<(), CliError> {
    let deadline = Instant::now() + DETACHED_START_TIMEOUT;
    let expected_socket = config.socket_path.display().to_string();
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| CliErrorKind::workflow_io(format!("poll bridge start: {error}")))?
        {
            return Err(detached_start_failure(status, stdout_path, stderr_path));
        }

        if let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)?
            && running.state.pid == child.id()
            && running.report.running
            && running.report.socket_path.as_deref() == Some(expected_socket.as_str())
        {
            return Ok(());
        }

        if Instant::now() >= deadline {
            let stdout_hint = log_excerpt(stdout_path);
            let stderr_hint = log_excerpt(stderr_path);
            return Err(CliErrorKind::workflow_io(format!(
                "bridge start timed out before publishing live state for {} (stdout log: {}; stderr log: {}; stdout tail: {}; stderr tail: {})",
                expected_socket,
                stdout_path.display(),
                stderr_path.display(),
                stdout_hint,
                stderr_hint
            ))
            .into());
        }

        thread::sleep(DETACHED_START_POLL_INTERVAL);
    }
}

fn detached_start_failure(status: ExitStatus, stdout_path: &Path, stderr_path: &Path) -> CliError {
    CliErrorKind::workflow_io(format!(
        "bridge background child exited early with status {status} (stdout log: {}; stderr log: {}; stdout tail: {}; stderr tail: {})",
        stdout_path.display(),
        stderr_path.display(),
        log_excerpt(stdout_path),
        log_excerpt(stderr_path)
    ))
    .into()
}

fn log_excerpt(path: &Path) -> String {
    let Ok(contents) = fs::read_to_string(path) else {
        return "unavailable".to_string();
    };
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        return "empty".to_string();
    }
    let lines: Vec<&str> = trimmed.lines().collect();
    let start = lines.len().saturating_sub(4);
    lines[start..].join(" | ")
}

fn wait_until_dead(pid: u32, grace: Duration) -> Result<(), CliError> {
    if wait_until_pid_dead(pid, grace) {
        return Ok(());
    }
    send_sigterm(pid)?;
    if wait_until_pid_dead(pid, grace) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "bridge stop: pid {pid} still alive after {}s",
        grace.as_secs()
    ))
    .into())
}

fn wait_until<F>(grace: Duration, mut predicate: F) -> bool
where
    F: FnMut() -> bool,
{
    let start = Instant::now();
    while start.elapsed() < grace {
        if predicate() {
            return true;
        }
        thread::sleep(STOP_POLL_INTERVAL);
    }
    false
}

fn wait_until_bridge_lock_released(grace: Duration) -> bool {
    wait_until(grace, || !bridge_lock_is_held())
}

fn wait_until_bridge_rpc_unavailable(client: &BridgeClient, grace: Duration) -> bool {
    wait_until(grace, || client.status().is_err())
}

fn force_stop_via_signal_if_possible(
    running: &ResolvedRunningBridge,
    grace: Duration,
    wait_for_stop: impl Fn() -> bool,
) -> Result<bool, CliError> {
    if super::service::sandboxed_from_env() || !pid_alive(running.state.pid) {
        return Ok(false);
    }
    send_sigterm(running.state.pid)?;
    Ok(wait_for_stop() || wait_until_pid_dead(running.state.pid, grace))
}

fn wait_until_bridge_dead(
    running: &ResolvedRunningBridge,
    grace: Duration,
) -> Result<(), CliError> {
    match running.proof {
        BridgeProof::Lock => {
            if wait_until_bridge_lock_released(grace) {
                return Ok(());
            }
            if force_stop_via_signal_if_possible(running, grace, || {
                wait_until_bridge_lock_released(grace)
            })? {
                return Ok(());
            }
            Err(CliErrorKind::workflow_io(format!(
                "bridge stop: bridge.lock still held after {}s",
                grace.as_secs()
            ))
            .into())
        }
        BridgeProof::Rpc => {
            let Some(client) = running.client.as_ref() else {
                return Err(CliErrorKind::workflow_io(
                    "bridge stop: live RPC proof missing client",
                )
                .into());
            };
            if wait_until_bridge_rpc_unavailable(client, grace) {
                return Ok(());
            }
            if force_stop_via_signal_if_possible(running, grace, || {
                wait_until_bridge_rpc_unavailable(client, grace)
            })? {
                return Ok(());
            }
            Err(CliErrorKind::workflow_io(format!(
                "bridge stop: bridge RPC still responding after {}s",
                grace.as_secs()
            ))
            .into())
        }
        BridgeProof::Pid => wait_until_dead(running.state.pid, grace),
    }
}

fn wait_until_pid_dead(pid: u32, grace: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < grace {
        if !pid_alive(pid) {
            return true;
        }
        thread::sleep(STOP_POLL_INTERVAL);
    }
    false
}

fn send_sigterm(pid: u32) -> Result<(), CliError> {
    let status = Command::new("/bin/kill")
        .args(["-TERM", &pid.to_string()])
        .status()
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("run /bin/kill -TERM {pid}: {error}"))
        })?;
    if status.success() || !pid_alive(pid) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!("/bin/kill -TERM {pid} exited with {status}")).into())
}

fn bridge_response_error(response: BridgeResponse) -> CliError {
    let code = response.code.unwrap_or_else(|| "UNKNOWN".to_string());
    let message = response
        .message
        .unwrap_or_else(|| "unknown bridge error".to_string());
    let detail = bridge_response_detail(&message);
    let error = match code.as_str() {
        "SANDBOX001" => CliError::from(CliErrorKind::sandbox_feature_disabled(detail)),
        "CODEX001" => CliError::from(CliErrorKind::codex_server_unavailable(detail)),
        "WORKFLOW_PARSE" => CliError::from(CliErrorKind::workflow_parse(message)),
        "WORKFLOW_SERIALIZE" => CliError::from(CliErrorKind::workflow_serialize(detail)),
        "WORKFLOW_VERSION" => CliError::from(CliErrorKind::workflow_version(detail)),
        "WORKFLOW_CONCURRENT" => CliError::from(CliErrorKind::concurrent_modification(detail)),
        "KSRCLI090" => CliError::from(CliErrorKind::session_not_active(detail)),
        "KSRCLI091" => CliError::from(CliErrorKind::session_permission_denied(detail)),
        "KSRCLI092" => CliError::from(CliErrorKind::session_agent_conflict(detail)),
        "WORKFLOW_IO" => CliError::from(CliErrorKind::workflow_io(message)),
        _ => CliError::from(CliErrorKind::workflow_io(format!(
            "bridge error {code}: {message}"
        ))),
    };
    if let Some(details) = response.details {
        error.with_details(details)
    } else {
        error
    }
}

fn bridge_response_detail(message: &str) -> String {
    message.split_once(": ").map_or_else(
        || message.trim().to_string(),
        |(_, detail)| detail.trim().to_string(),
    )
}

fn parse_bridge_payload<T: DeserializeOwned>(payload: Value) -> Result<T, CliError> {
    serde_json::from_value(payload).map_err(|error| {
        CliErrorKind::workflow_parse(format!("decode bridge payload: {error}")).into()
    })
}

fn stringify_metadata_map<T: Serialize>(value: &T) -> BTreeMap<String, String> {
    let Ok(Value::Object(entries)) = serde_json::to_value(value) else {
        return BTreeMap::new();
    };
    entries
        .into_iter()
        .filter_map(|(key, value)| {
            let value = match value {
                Value::Null => return None,
                Value::String(value) => value,
                other => other.to_string(),
            };
            Some((key, value))
        })
        .collect()
}

fn print_json(report: &BridgeStatusReport) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

fn print_status_plain(report: &BridgeStatusReport) {
    if report.running {
        let socket = report.socket_path.as_deref().unwrap_or("?");
        let pid = report
            .pid
            .map_or_else(|| "?".to_string(), |pid| pid.to_string());
        let capabilities = report
            .capabilities
            .keys()
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        println!("running at {socket} (pid {pid}; capabilities: {capabilities})");
    } else {
        println!("not running");
    }
}

fn remove_if_exists(path: &Path) -> Result<(), CliError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => {
            Err(CliErrorKind::workflow_io(format!("remove {}: {error}", path.display())).into())
        }
    }
}

fn resolve_codex_binary(explicit: Option<&Path>) -> Result<PathBuf, CliError> {
    if let Some(path) = explicit {
        if path.is_file() {
            return Ok(path.to_path_buf());
        }
        return Err(CliErrorKind::workflow_io(format!(
            "codex binary not found at {}",
            path.display()
        ))
        .into());
    }
    if let Some(path) = find_on_path("codex") {
        return Ok(path);
    }
    Err(CliErrorKind::workflow_io(
        "codex binary not found on PATH; use --codex-path to specify it".to_string(),
    )
    .into())
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
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

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
    let duration = Utc::now().signed_duration_since(started);
    u64::try_from(duration.num_seconds()).ok()
}

fn launch_agent_plist_path() -> Result<PathBuf, CliError> {
    let home = var("HOME").map_err(|_| {
        CliErrorKind::workflow_io("HOME is not set; cannot determine LaunchAgent path")
    })?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{BRIDGE_LAUNCH_AGENT_LABEL}.plist")))
}

fn render_launch_agent_plist(harness_binary: &Path) -> String {
    let args = [
        format!("<string>{}</string>", harness_binary.display()),
        "<string>bridge</string>".to_string(),
        "<string>start</string>".to_string(),
    ];
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    {arguments}
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
        label = BRIDGE_LAUNCH_AGENT_LABEL,
        arguments = args.join("\n    "),
        stdout = state::daemon_root().join("bridge.stdout.log").display(),
        stderr = state::daemon_root().join("bridge.stderr.log").display(),
    )
}

fn merged_persisted_config(
    explicit: &BridgeConfigArgs,
    persisted: Option<PersistedBridgeConfig>,
) -> PersistedBridgeConfig {
    let persisted = persisted.unwrap_or_else(|| PersistedBridgeConfig {
        capabilities: compiled_capabilities().into_iter().collect(),
        ..PersistedBridgeConfig::default()
    });
    PersistedBridgeConfig {
        capabilities: if explicit.capabilities.is_empty() {
            persisted.capabilities
        } else {
            explicit.capabilities.clone()
        },
        socket_path: explicit.socket_path.clone().or(persisted.socket_path),
        codex_port: explicit.codex_port.or(persisted.codex_port),
        codex_path: explicit.codex_path.clone().or(persisted.codex_path),
    }
    .normalized()
}

fn resolve_bridge_config(config: PersistedBridgeConfig) -> Result<ResolvedBridgeConfig, CliError> {
    let persisted = config.normalized();
    let capabilities = persisted.capabilities_set();
    let socket_path = persisted
        .socket_path
        .clone()
        .unwrap_or_else(bridge_socket_path);
    let codex_port = persisted.codex_port.unwrap_or(DEFAULT_CODEX_BRIDGE_PORT);
    let codex_binary = if capabilities.contains(&BridgeCapability::Codex) {
        Some(resolve_codex_binary(persisted.codex_path.as_deref())?)
    } else {
        None
    };
    Ok(ResolvedBridgeConfig {
        persisted,
        capabilities,
        socket_path,
        codex_port,
        codex_binary,
    })
}

fn best_effort_bootout(label: &str) {
    if !cfg!(target_os = "macos") {
        return;
    }
    let target = format!("gui/{}/{}", uzers::get_current_uid(), label);
    let _ = Command::new("launchctl")
        .args(["bootout", &target])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn bootstrap_agent(plist_path: &Path) -> Result<(), CliError> {
    let domain = format!("gui/{}", uzers::get_current_uid());
    let output = Command::new("launchctl")
        .args(["bootstrap", &domain, &plist_path.display().to_string()])
        .output()
        .map_err(|error| CliErrorKind::workflow_io(format!("run launchctl bootstrap: {error}")))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.to_ascii_lowercase().contains("already loaded")
        || stderr.to_ascii_lowercase().contains("already bootstrapped")
    {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!("launchctl bootstrap failed: {stderr}")).into())
}

fn cleanup_legacy_bridge_artifacts() {
    if cfg!(target_os = "macos") {
        best_effort_bootout("io.harness.codex-bridge");
        best_effort_bootout("io.harness.agent-tui-bridge");
    }
    let _ = remove_if_exists(&state::daemon_root().join("codex-endpoint.json"));
    let _ = remove_if_exists(&state::daemon_root().join("codex-bridge.pid"));
    let _ = remove_if_exists(&state::daemon_root().join("codex-bridge.stdout.log"));
    let _ = remove_if_exists(&state::daemon_root().join("codex-bridge.stderr.log"));
    let _ = remove_if_exists(&state::daemon_root().join("agent-tui-bridge.stdout.log"));
    let _ = remove_if_exists(&state::daemon_root().join("agent-tui-bridge.stderr.log"));
    let legacy_agent_tui_state = state::daemon_root().join("agent-tui-bridge.json");
    if let Ok(data) = fs::read_to_string(&legacy_agent_tui_state)
        && let Ok(value) = serde_json::from_str::<Value>(&data)
        && let Some(socket_path) = value.get("socket_path").and_then(Value::as_str)
    {
        let _ = remove_if_exists(Path::new(socket_path));
    }
    let _ = remove_if_exists(&legacy_agent_tui_state);
    let _ = remove_if_exists(&state::daemon_root().join("agent-tui-bridge.sock"));
    if let Ok(home) = var("HOME") {
        let launch_agents = PathBuf::from(home).join("Library").join("LaunchAgents");
        let _ = remove_if_exists(&launch_agents.join("io.harness.codex-bridge.plist"));
        let _ = remove_if_exists(&launch_agents.join("io.harness.agent-tui-bridge.plist"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener as StdUnixListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Instant;

    use fs2::FileExt;
    use tempfile::tempdir;

    fn with_temp_daemon_root<F: FnOnce()>(f: F) {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_SANDBOXED", None),
                ("XDG_DATA_HOME", None),
            ],
            f,
        );
    }

    #[test]
    fn compiled_capabilities_default_to_all_known_entries() {
        let capabilities = compiled_capabilities();
        assert!(capabilities.contains(&BridgeCapability::Codex));
        assert!(capabilities.contains(&BridgeCapability::AgentTui));
    }

    #[test]
    fn config_defaults_to_all_capabilities() {
        let merged = merged_persisted_config(
            &BridgeConfigArgs {
                capabilities: Vec::new(),
                socket_path: None,
                codex_port: None,
                codex_path: None,
            },
            None,
        );
        assert_eq!(merged.capabilities_set(), compiled_capabilities());
    }

    #[test]
    fn config_honors_explicit_capability_subset_and_persisted_defaults() {
        let merged = merged_persisted_config(
            &BridgeConfigArgs {
                capabilities: vec![BridgeCapability::AgentTui],
                socket_path: None,
                codex_port: None,
                codex_path: None,
            },
            Some(PersistedBridgeConfig {
                capabilities: vec![BridgeCapability::Codex],
                socket_path: Some(PathBuf::from("/tmp/custom.sock")),
                codex_port: Some(14567),
                codex_path: Some(PathBuf::from("/tmp/mock-codex")),
            }),
        );
        assert_eq!(
            merged.capabilities_set(),
            BTreeSet::from([BridgeCapability::AgentTui])
        );
        assert_eq!(merged.socket_path, Some(PathBuf::from("/tmp/custom.sock")));
        assert_eq!(merged.codex_port, Some(14567));
        assert_eq!(merged.codex_path, Some(PathBuf::from("/tmp/mock-codex")));
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
            let state = BridgeState {
                socket_path: "/tmp/bridge.sock".to_string(),
                pid: process_id(),
                started_at: "2026-04-11T12:00:00Z".to_string(),
                token_path: "/tmp/auth-token".to_string(),
                capabilities: BTreeMap::from([(
                    BRIDGE_CAPABILITY_CODEX.to_string(),
                    HostBridgeCapabilityManifest {
                        enabled: true,
                        healthy: true,
                        transport: "websocket".to_string(),
                        endpoint: Some("ws://127.0.0.1:4500".to_string()),
                        metadata: BTreeMap::from([("port".to_string(), "4500".to_string())]),
                    },
                )]),
            };
            write_bridge_state(&state).expect("write");
            let loaded = read_bridge_state().expect("read").expect("state");
            assert_eq!(loaded, state);
        });
    }

    #[test]
    fn write_then_read_roundtrips_bridge_config() {
        with_temp_daemon_root(|| {
            let config = PersistedBridgeConfig {
                capabilities: vec![BridgeCapability::AgentTui],
                socket_path: Some(PathBuf::from("/tmp/bridge.sock")),
                codex_port: Some(14500),
                codex_path: Some(PathBuf::from("/tmp/mock-codex")),
            };
            write_bridge_config(&config).expect("write");
            let loaded = read_bridge_config().expect("read").expect("config");
            assert_eq!(loaded, config);
        });
    }

    #[test]
    fn reconfigure_spec_rejects_duplicate_and_conflicting_capabilities() {
        let duplicate = BridgeReconfigureSpec {
            enable: vec![BridgeCapability::Codex, BridgeCapability::Codex],
            disable: Vec::new(),
            force: false,
        };
        assert_eq!(
            duplicate.validate().expect_err("duplicate enable").code(),
            "WORKFLOW_PARSE"
        );

        let conflicting = BridgeReconfigureSpec {
            enable: vec![BridgeCapability::Codex],
            disable: vec![BridgeCapability::Codex],
            force: false,
        };
        assert_eq!(
            conflicting.validate().expect_err("conflict").code(),
            "WORKFLOW_PARSE"
        );
    }

    #[test]
    fn reconfigure_names_reject_unknown_capability() {
        let error = BridgeReconfigureSpec::from_names(
            &[String::from("codex")],
            &[String::from("unknown")],
            false,
        )
        .expect_err("unknown capability");
        assert_eq!(error.code(), "WORKFLOW_PARSE");
    }

    #[test]
    fn bridge_response_error_preserves_session_agent_conflict_code() {
        let error = bridge_response_error(BridgeResponse {
            ok: false,
            code: Some("KSRCLI092".to_string()),
            message: Some(
                "session agent conflict: agent-tui capability has 1 active session(s); rerun with --force to stop them first"
                    .to_string(),
            ),
            details: None,
            payload: None,
        });

        assert_eq!(error.code(), "KSRCLI092");
        assert!(
            error
                .message()
                .contains("agent-tui capability has 1 active session(s)")
        );
    }

    #[test]
    fn host_bridge_manifest_reflects_running_bridge_state() {
        with_temp_daemon_root(|| {
            let state = BridgeState {
                socket_path: "/tmp/bridge.sock".to_string(),
                pid: process_id(),
                started_at: "2026-04-11T12:00:00Z".to_string(),
                token_path: "/tmp/auth-token".to_string(),
                capabilities: BTreeMap::from([(
                    BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
                    HostBridgeCapabilityManifest {
                        enabled: true,
                        healthy: true,
                        transport: "unix".to_string(),
                        endpoint: Some("/tmp/bridge.sock".to_string()),
                        metadata: BTreeMap::from([(
                            "active_sessions".to_string(),
                            "0".to_string(),
                        )]),
                    },
                )]),
            };
            write_bridge_state(&state).expect("write");
            // host_bridge_manifest uses LockOnly; hold the lock so it sees the
            // bridge as running (the previous behavior relied on pid_alive).
            let _flock = hold_bridge_lock();

            let manifest = host_bridge_manifest().expect("manifest");
            assert!(manifest.running);
            assert_eq!(manifest.socket_path.as_deref(), Some("/tmp/bridge.sock"));
            assert!(
                manifest
                    .capabilities
                    .contains_key(BRIDGE_CAPABILITY_AGENT_TUI)
            );
        });
    }

    #[test]
    fn host_bridge_manifest_defaults_when_bridge_missing() {
        with_temp_daemon_root(|| {
            assert_eq!(
                host_bridge_manifest().expect("manifest"),
                HostBridgeManifest::default()
            );
        });
    }

    #[test]
    fn bridge_client_for_capability_rejects_missing_capability() {
        with_temp_daemon_root(|| {
            let state = BridgeState {
                socket_path: "/tmp/bridge.sock".to_string(),
                pid: process_id(),
                started_at: "2026-04-11T12:00:00Z".to_string(),
                token_path: "/tmp/auth-token".to_string(),
                capabilities: BTreeMap::from([(
                    BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
                    HostBridgeCapabilityManifest {
                        enabled: true,
                        healthy: true,
                        transport: "unix".to_string(),
                        endpoint: Some("/tmp/bridge.sock".to_string()),
                        metadata: BTreeMap::new(),
                    },
                )]),
            };
            write_bridge_state(&state).expect("write");

            let error = BridgeClient::for_capability(BridgeCapability::Codex)
                .expect_err("codex capability should be rejected");
            assert_eq!(error.code(), "SANDBOX001");
            assert!(error.to_string().contains("codex.host-bridge"));
        });
    }

    #[test]
    fn bridge_socket_guard_unlinks_on_drop() {
        let tmp = tempdir().expect("tempdir");
        let socket_path = tmp.path().join("fake.sock");
        fs::write(&socket_path, b"").expect("seed fake socket");
        assert!(socket_path.exists());

        {
            let _guard = BridgeSocketGuard::new(socket_path.clone());
        }

        assert!(
            !socket_path.exists(),
            "armed guard must unlink the socket file on drop"
        );
    }

    #[test]
    fn bridge_socket_guard_disarmed_preserves_file() {
        let tmp = tempdir().expect("tempdir");
        let socket_path = tmp.path().join("fake.sock");
        fs::write(&socket_path, b"keep").expect("seed fake socket");

        {
            let mut guard = BridgeSocketGuard::new(socket_path.clone());
            guard.disarm();
        }

        assert!(
            socket_path.exists(),
            "disarmed guard must leave the socket file in place"
        );
        assert_eq!(
            fs::read(&socket_path).expect("read file"),
            b"keep",
            "file contents must be untouched"
        );
    }

    #[test]
    fn bridge_socket_guard_drop_is_idempotent_when_file_missing() {
        let tmp = tempdir().expect("tempdir");
        let socket_path = tmp.path().join("never-existed.sock");
        assert!(!socket_path.exists());

        // Dropping the armed guard for a non-existent path must not panic
        // and must not emit a warn log (NotFound is intentionally silenced).
        let _guard = BridgeSocketGuard::new(socket_path);
    }

    #[test]
    fn bridge_socket_path_falls_back_for_long_root() {
        let tmp = tempdir().expect("tempdir");
        let long_root = tmp.path().join(
            "very/long/path/for/a/daemon/root/that/would/overflow/the/unix/socket/path/limit/on/macos",
        );
        let path = bridge_socket_path_for_root(&long_root);
        assert!(path.starts_with("/tmp"));
        assert!(unix_socket_path_fits(&path));
    }

    #[test]
    fn bridge_socket_fallback_uses_group_container_when_nested() {
        // Fully synthetic daemon root that mirrors the sandboxed shape
        // `{prefix}/Library/Group Containers/{group}/harness/daemon`.
        // Chosen so that `{daemon_root}/bridge.sock` exceeds the 103-byte
        // AF_UNIX `sun_path` limit (forcing the fallback to run) while the
        // group container root still has enough headroom for a shortened
        // hash suffix, independent of the host running the test.
        let group_container = PathBuf::from(
            "/private/sandbox-test-user/Library/Group Containers/Q498EB36N4.io.harnessmonitor",
        );
        let daemon_root = group_container.join("harness/daemon");

        let preferred = daemon_root.join(DEFAULT_BRIDGE_SOCKET_NAME);
        assert!(
            !unix_socket_path_fits(&preferred),
            "regression guard: preferred path must exceed the 103-byte limit so the fallback runs ({} bytes)",
            preferred.as_os_str().len(),
        );

        let path = bridge_socket_path_for_root(&daemon_root);
        assert!(
            unix_socket_path_fits(&path),
            "fallback path must fit within UNIX_SOCKET_PATH_LIMIT: {} ({} bytes)",
            path.display(),
            path.as_os_str().len(),
        );
        assert!(
            path.starts_with(&group_container),
            "fallback must land inside the group container, got {}",
            path.display()
        );
        assert!(
            !path.starts_with("/tmp"),
            "sandboxed daemons cannot reach /tmp; fallback must avoid it, got {}",
            path.display()
        );
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .expect("fallback socket file name");
        assert!(
            file_name.starts_with("h-") && file_name.ends_with(FALLBACK_BRIDGE_SOCKET_SUFFIX),
            "unexpected fallback file name: {file_name}"
        );
    }

    #[test]
    fn group_container_root_detects_nested_path() {
        let daemon_root = PathBuf::from(
            "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/daemon",
        );
        assert_eq!(
            group_container_root(&daemon_root),
            Some(PathBuf::from(
                "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor"
            ))
        );
    }

    #[test]
    fn group_container_root_returns_none_outside_container() {
        assert!(
            group_container_root(&PathBuf::from(
                "/Users/example/Library/Application Support/harness/daemon"
            ))
            .is_none()
        );
        assert!(group_container_root(&PathBuf::from("/tmp/harness/daemon")).is_none());
    }

    // --- bridge.lock unit tests ---

    #[test]
    fn acquire_bridge_lock_succeeds_when_unheld() {
        with_temp_daemon_root(|| {
            let _guard = acquire_bridge_lock_exclusive().expect("first acquire should succeed");
            assert!(bridge_lock_path().exists(), "lock file should exist");
        });
    }

    #[test]
    fn acquire_bridge_lock_fails_when_another_holder_exists() {
        with_temp_daemon_root(|| {
            let _guard = acquire_bridge_lock_exclusive().expect("first acquire");
            let error = acquire_bridge_lock_exclusive().expect_err("second acquire should fail");
            assert!(
                error.to_string().contains("bridge"),
                "error should mention bridge: {error}"
            );
        });
    }

    #[test]
    fn bridge_lock_guard_releases_on_drop() {
        with_temp_daemon_root(|| {
            let guard = acquire_bridge_lock_exclusive().expect("acquire");
            drop(guard);
            let _guard2 =
                acquire_bridge_lock_exclusive().expect("re-acquire after drop should succeed");
        });
    }

    #[test]
    fn bridge_lock_is_held_is_false_when_no_holder() {
        with_temp_daemon_root(|| {
            assert!(
                !state::flock_is_held_at(&bridge_lock_path()),
                "no holder yet"
            );
        });
    }

    #[test]
    fn bridge_lock_is_held_is_true_while_guard_is_alive() {
        with_temp_daemon_root(|| {
            let guard = acquire_bridge_lock_exclusive().expect("acquire");
            assert!(
                state::flock_is_held_at(&bridge_lock_path()),
                "should be held"
            );
            drop(guard);
            assert!(
                !state::flock_is_held_at(&bridge_lock_path()),
                "should be released"
            );
        });
    }

    #[test]
    fn clear_bridge_state_removes_lock_file() {
        with_temp_daemon_root(|| {
            state::ensure_daemon_dirs().expect("dirs");
            // Create the lock file as if the bridge had been running.
            std::fs::write(bridge_lock_path(), "").expect("create lock file");
            clear_bridge_state().expect("clear");
            assert!(!bridge_lock_path().exists(), "lock file should be removed");
        });
    }

    // --- LivenessMode / load_running_bridge_state unit tests ---

    fn write_fake_bridge_state(pid: u32) {
        state::ensure_daemon_dirs().expect("dirs");
        let bridge_state = BridgeState {
            socket_path: "/tmp/fake-bridge.sock".to_string(),
            pid,
            started_at: "2026-04-11T17:00:00Z".to_string(),
            token_path: "/tmp/fake-token".to_string(),
            capabilities: BTreeMap::new(),
        };
        write_bridge_state(&bridge_state).expect("write bridge state");
    }

    /// Acquire an exclusive flock by hand and keep the file open so the flock
    /// persists for the duration of the caller's scope. Mirrors the
    /// `fake_running_daemon` pattern in discovery tests.
    fn hold_bridge_lock() -> std::fs::File {
        state::ensure_daemon_dirs().expect("dirs");
        let path = bridge_lock_path();
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&path)
            .expect("open bridge lock");
        file.try_lock_exclusive().expect("flock bridge lock");
        file
    }

    fn legacy_codex_capabilities() -> BTreeMap<String, HostBridgeCapabilityManifest> {
        BTreeMap::from([(
            BRIDGE_CAPABILITY_CODEX.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "websocket".to_string(),
                endpoint: Some("ws://127.0.0.1:4500".to_string()),
                metadata: BTreeMap::from([("port".to_string(), "4500".to_string())]),
            },
        )])
    }

    #[derive(Debug, Clone, Copy)]
    enum LegacyShutdownBehavior {
        ExitAfter(Duration),
        Ignore,
    }

    #[derive(Debug)]
    struct LegacyBridgeServer {
        socket_path: PathBuf,
        token: String,
        terminate: Arc<AtomicBool>,
        join: Option<thread::JoinHandle<()>>,
    }

    impl LegacyBridgeServer {
        fn start(
            capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
            shutdown_behavior: LegacyShutdownBehavior,
        ) -> Self {
            state::ensure_daemon_dirs().expect("dirs");
            let socket_path = state::daemon_root().join("legacy-bridge-test.sock");
            let token_path = state::daemon_root().join("legacy-bridge-token");
            let token = "legacy-bridge-token".to_string();
            let terminate = Arc::new(AtomicBool::new(false));
            let _ = remove_if_exists(&socket_path);
            fs::write(&token_path, &token).expect("write token");
            write_bridge_state(&BridgeState {
                socket_path: socket_path.display().to_string(),
                pid: 999_999_999,
                started_at: "2026-04-11T17:00:00Z".to_string(),
                token_path: token_path.display().to_string(),
                capabilities: capabilities.clone(),
            })
            .expect("write bridge state");

            let listener = StdUnixListener::bind(&socket_path).expect("bind legacy bridge socket");
            let report = BridgeStatusReport {
                running: true,
                socket_path: Some(socket_path.display().to_string()),
                pid: Some(999_999_999),
                started_at: Some("2026-04-11T17:00:00Z".to_string()),
                uptime_seconds: Some(1),
                capabilities,
            };
            let thread_socket_path = socket_path.clone();
            let thread_token = token.clone();
            let thread_terminate = Arc::clone(&terminate);
            let join = thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else {
                        break;
                    };
                    let mut line = String::new();
                    BufReader::new(stream.try_clone().expect("clone stream"))
                        .read_line(&mut line)
                        .expect("read request");
                    let envelope: BridgeEnvelope =
                        serde_json::from_str(&line).expect("parse bridge envelope");
                    let request = envelope.request.clone();
                    let response = if envelope.token != thread_token {
                        BridgeResponse::error(&CliError::from(CliErrorKind::workflow_io(
                            "bridge token mismatch",
                        )))
                    } else {
                        match request {
                            BridgeRequest::Status => {
                                BridgeResponse::ok_payload(&report).expect("status response")
                            }
                            BridgeRequest::Shutdown => BridgeResponse::empty_ok(),
                            _ => BridgeResponse::error(&CliError::from(
                                CliErrorKind::workflow_parse("unsupported legacy test request"),
                            )),
                        }
                    };
                    let payload = serde_json::to_string(&response).expect("serialize response");
                    stream
                        .write_all(payload.as_bytes())
                        .expect("write response");
                    stream.write_all(b"\n").expect("write newline");
                    stream.flush().expect("flush response");

                    if thread_terminate.load(Ordering::SeqCst) {
                        break;
                    }
                    if matches!(request, BridgeRequest::Shutdown) {
                        match shutdown_behavior {
                            LegacyShutdownBehavior::ExitAfter(delay) => {
                                thread::sleep(delay);
                                break;
                            }
                            LegacyShutdownBehavior::Ignore => {}
                        }
                    }
                }
                let _ = std::fs::remove_file(&thread_socket_path);
            });

            Self {
                socket_path,
                token,
                terminate,
                join: Some(join),
            }
        }

        fn wake(&self) {
            let _ = BridgeClient {
                socket_path: self.socket_path.clone(),
                token: self.token.clone(),
            }
            .status();
        }
    }

    impl Drop for LegacyBridgeServer {
        fn drop(&mut self) {
            self.terminate.store(true, Ordering::SeqCst);
            self.wake();
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
            let _ = std::fs::remove_file(&self.socket_path);
        }
    }

    #[test]
    fn load_running_bridge_state_returns_none_when_no_state_file() {
        with_temp_daemon_root(|| {
            assert!(
                load_running_bridge_state(LivenessMode::LockOnly)
                    .expect("load")
                    .is_none()
            );
            assert!(
                load_running_bridge_state(LivenessMode::HostAuthoritative)
                    .expect("load")
                    .is_none()
            );
        });
    }

    #[test]
    fn load_running_bridge_state_returns_state_when_bridge_lock_held() {
        with_temp_daemon_root(|| {
            write_fake_bridge_state(99999999);
            let _flock = hold_bridge_lock();
            // Both modes return Some when the flock is held.
            assert!(
                load_running_bridge_state(LivenessMode::LockOnly)
                    .expect("lock-only")
                    .is_some()
            );
            assert!(
                load_running_bridge_state(LivenessMode::HostAuthoritative)
                    .expect("host-auth")
                    .is_some()
            );
        });
    }

    #[test]
    fn load_running_bridge_state_returns_state_when_bridge_rpc_succeeds_without_lock() {
        with_temp_daemon_root(|| {
            let _server = LegacyBridgeServer::start(
                BTreeMap::new(),
                LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
            );
            assert!(
                load_running_bridge_state(LivenessMode::LockOnly)
                    .expect("lock-only")
                    .is_some()
            );
            assert!(
                load_running_bridge_state(LivenessMode::HostAuthoritative)
                    .expect("host-auth")
                    .is_some()
            );
        });
    }

    #[test]
    fn load_running_bridge_state_returns_none_when_neither_lock_nor_pid_live() {
        with_temp_daemon_root(|| {
            // pid 99999999 is definitely not alive.
            write_fake_bridge_state(99999999);
            assert!(
                load_running_bridge_state(LivenessMode::LockOnly)
                    .expect("lock-only")
                    .is_none()
            );
            assert!(
                load_running_bridge_state(LivenessMode::HostAuthoritative)
                    .expect("host-auth")
                    .is_none()
            );
        });
    }

    /// The critical regression test. The consumer path must never delete
    /// bridge.json regardless of what it finds. This is the test that would
    /// have caught the original v19.6.0 bug.
    #[test]
    fn load_running_bridge_state_does_not_delete_state_file() {
        with_temp_daemon_root(|| {
            write_fake_bridge_state(99999999);
            let _ = load_running_bridge_state(LivenessMode::LockOnly).expect("lock-only");
            assert!(
                bridge_state_path().exists(),
                "bridge.json must survive a LockOnly load with a dead pid"
            );
            let _ = load_running_bridge_state(LivenessMode::HostAuthoritative).expect("host-auth");
            assert!(
                bridge_state_path().exists(),
                "bridge.json must survive a HostAuthoritative load with a dead pid"
            );
        });
    }

    #[test]
    fn load_running_bridge_state_lock_only_ignores_pid_alive_fallback() {
        with_temp_daemon_root(|| {
            // Use the current process pid — guaranteed alive under /bin/kill -0.
            write_fake_bridge_state(process_id());
            // LockOnly must return None because no flock is held, even though
            // the pid is alive.
            assert!(
                load_running_bridge_state(LivenessMode::LockOnly)
                    .expect("lock-only")
                    .is_none(),
                "LockOnly must not fall back to pid_alive"
            );
            // HostAuthoritative must return Some via the pid fallback.
            assert!(
                load_running_bridge_state(LivenessMode::HostAuthoritative)
                    .expect("host-auth")
                    .is_some(),
                "HostAuthoritative must fall back to pid_alive when no lock held"
            );
        });
    }

    #[test]
    fn load_running_bridge_state_host_authoritative_returns_state_when_only_pid_alive() {
        with_temp_daemon_root(|| {
            // Simulates a pre-19.7.0 bridge: state file present, no bridge.lock.
            write_fake_bridge_state(process_id());
            assert!(
                load_running_bridge_state(LivenessMode::HostAuthoritative)
                    .expect("host-auth")
                    .is_some(),
                "backward-compat: HostAuthoritative must return state when only pid is alive"
            );
        });
    }

    #[test]
    fn host_bridge_manifest_uses_rpc_for_legacy_bridge_without_lock() {
        with_temp_daemon_root(|| {
            let _server = LegacyBridgeServer::start(
                legacy_codex_capabilities(),
                LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
            );
            let manifest = host_bridge_manifest().expect("manifest");
            assert!(manifest.running);
            assert_eq!(
                manifest
                    .capabilities
                    .get(BRIDGE_CAPABILITY_CODEX)
                    .and_then(|capability| capability.endpoint.as_deref()),
                Some("ws://127.0.0.1:4500")
            );
        });
    }

    #[test]
    fn status_report_uses_rpc_when_sandboxed_legacy_bridge_is_live() {
        with_temp_daemon_root(|| {
            let _server = LegacyBridgeServer::start(
                BTreeMap::new(),
                LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
            );
            temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
                let report = status_report().expect("status");
                assert!(report.running);
                assert_eq!(report.pid, Some(999_999_999));
            });
        });
    }

    #[test]
    fn bridge_client_for_capability_accepts_live_legacy_bridge_without_lock() {
        with_temp_daemon_root(|| {
            let _server = LegacyBridgeServer::start(
                legacy_codex_capabilities(),
                LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
            );
            let client =
                BridgeClient::for_capability(BridgeCapability::Codex).expect("codex client");
            let report = client.status().expect("status");
            assert!(report.running);
            assert!(report.capabilities.contains_key(BRIDGE_CAPABILITY_CODEX));
        });
    }

    #[test]
    fn wait_until_bridge_dead_returns_error_when_rpc_proof_stays_live_in_sandbox() {
        with_temp_daemon_root(|| {
            let _server =
                LegacyBridgeServer::start(BTreeMap::new(), LegacyShutdownBehavior::Ignore);
            temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
                let running = resolve_running_bridge(LivenessMode::HostAuthoritative)
                    .expect("resolve running bridge")
                    .expect("running bridge");
                assert_eq!(running.proof, BridgeProof::Rpc);
                let error = wait_until_bridge_dead(&running, Duration::from_millis(150))
                    .expect_err("rpc proof should remain live");
                assert!(error.to_string().contains("still responding"));
            });
        });
    }

    #[test]
    fn stop_bridge_waits_for_rpc_proof_to_disappear_before_clearing_state() {
        with_temp_daemon_root(|| {
            let _server = LegacyBridgeServer::start(
                legacy_codex_capabilities(),
                LegacyShutdownBehavior::ExitAfter(Duration::from_millis(250)),
            );
            let started = Instant::now();
            let report = stop_bridge().expect("stop bridge");
            assert!(
                started.elapsed() >= Duration::from_millis(200),
                "stop_bridge should wait until the RPC proof disappears"
            );
            assert!(
                !bridge_state_path().exists(),
                "bridge state should be cleared"
            );
            assert!(!report.running);
        });
    }

    #[test]
    fn compute_bridge_manifest_update_returns_none_when_host_bridge_unchanged() {
        with_temp_daemon_root(|| {
            // No bridge running: host_bridge_manifest() returns default.
            let current = state::DaemonManifest {
                version: env!("CARGO_PKG_VERSION").to_string(),
                pid: process_id(),
                endpoint: "http://127.0.0.1:7070".to_string(),
                started_at: "2026-04-11T00:00:00Z".to_string(),
                token_path: "/tmp/token".to_string(),
                sandboxed: true,
                host_bridge: HostBridgeManifest::default(),
                revision: 1,
                updated_at: "2026-04-11T00:00:00Z".to_string(),
            };
            // No bridge.json exists so host_bridge_manifest returns default.
            // current.host_bridge is already default, so no update needed.
            assert!(
                compute_bridge_manifest_update(&current).is_none(),
                "no update when host_bridge state is unchanged"
            );
        });
    }

    /// Direct regression test for the observed bug: watcher should publish a
    /// running=true manifest update when bridge.lock is held, without needing
    /// /bin/kill -0.
    #[test]
    fn compute_bridge_manifest_update_returns_some_when_lock_held_and_manifest_stale() {
        with_temp_daemon_root(|| {
            write_fake_bridge_state(99999999);
            let _flock = hold_bridge_lock();

            let current = state::DaemonManifest {
                version: env!("CARGO_PKG_VERSION").to_string(),
                pid: process_id(),
                endpoint: "http://127.0.0.1:7070".to_string(),
                started_at: "2026-04-11T00:00:00Z".to_string(),
                token_path: "/tmp/token".to_string(),
                sandboxed: true,
                // Manifest currently shows bridge as not running.
                host_bridge: HostBridgeManifest::default(),
                revision: 2,
                updated_at: "2026-04-11T00:00:00Z".to_string(),
            };
            let updated = compute_bridge_manifest_update(&current)
                .expect("update should be produced when lock held and manifest stale");
            assert!(
                updated.host_bridge.running,
                "updated manifest should reflect running=true"
            );
        });
    }
}
