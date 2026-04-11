use std::collections::{BTreeMap, BTreeSet};
use std::env::{current_exe, split_paths, var, var_os};
use std::fs::File;
use std::fs::Permissions;
use std::io::{BufRead, BufReader, ErrorKind, Write as _};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio, id as process_id};
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
use super::state::{self, HostBridgeCapabilityManifest, HostBridgeManifest};

pub const BRIDGE_LAUNCH_AGENT_LABEL: &str = "io.harness.bridge";
pub const BRIDGE_CAPABILITY_CODEX: &str = "codex";
pub const BRIDGE_CAPABILITY_AGENT_TUI: &str = "agent-tui";
pub const DEFAULT_CODEX_BRIDGE_PORT: u16 = 4500;
pub const CODEX_BRIDGE_PORT_ENV: &str = "HARNESS_CODEX_WS_PORT";

const STOP_GRACE_PERIOD: Duration = Duration::from_secs(5);
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);
const WATCH_DEBOUNCE: Duration = Duration::from_millis(200);
const DEFAULT_BRIDGE_SOCKET_NAME: &str = "bridge.sock";
const FALLBACK_BRIDGE_SOCKET_PREFIX: &str = "h-bridge-";
const FALLBACK_BRIDGE_SOCKET_SUFFIX: &str = ".sock";
const UNIX_SOCKET_PATH_LIMIT: usize = if cfg!(target_os = "macos") { 103 } else { 107 };

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, ValueEnum)]
pub enum BridgeCapability {
    Codex,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiBridgeStartSpec {
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
    #[must_use]
    fn selected_capabilities(&self) -> BTreeSet<BridgeCapability> {
        if self.capabilities.is_empty() {
            return compiled_capabilities();
        }
        self.capabilities.iter().copied().collect()
    }

    fn resolve(&self) -> Result<ResolvedBridgeConfig, CliError> {
        let capabilities = self.selected_capabilities();
        let socket_path = self.socket_path.clone().unwrap_or_else(bridge_socket_path);
        let codex_port = self.codex_port.unwrap_or(DEFAULT_CODEX_BRIDGE_PORT);
        let codex_binary = if capabilities.contains(&BridgeCapability::Codex) {
            Some(resolve_codex_binary(self.codex_path.as_deref())?)
        } else {
            None
        };
        Ok(ResolvedBridgeConfig {
            capabilities,
            socket_path,
            codex_port,
            codex_binary,
        })
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
            Self::InstallLaunchAgent(args) => args.execute(context),
            Self::RemoveLaunchAgent(args) => args.execute(context),
        }
    }
}

impl Execute for BridgeStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-start")?;
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
        cleanup_legacy_bridge_artifacts();
        let config = self.config.resolve()?;
        let harness_binary = current_exe().map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
        })?;
        let plist = render_launch_agent_plist(&harness_binary, &config);
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

impl Execute for BridgeRemoveLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-remove-launch-agent")?;
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

#[derive(Debug, Clone)]
struct ResolvedBridgeConfig {
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
            payload: Some(payload),
        })
    }

    const fn empty_ok() -> Self {
        Self {
            ok: true,
            code: None,
            message: None,
            payload: None,
        }
    }

    fn error(error: &CliError) -> Self {
        Self {
            ok: false,
            code: Some(error.code().to_string()),
            message: Some(error.to_string()),
            payload: None,
        }
    }
}

struct BridgeCodexProcess {
    child: Child,
    endpoint: String,
    metadata: BridgeCodexMetadata,
}

struct BridgeServer {
    token: String,
    socket_path: PathBuf,
    pid: u32,
    started_at: String,
    token_path: String,
    capabilities: Mutex<BTreeMap<String, HostBridgeCapabilityManifest>>,
    active_tuis: Mutex<BTreeMap<String, BridgeActiveTui>>,
    codex: Mutex<Option<BridgeCodexProcess>>,
    shutdown: AtomicBool,
}

impl BridgeServer {
    fn new(
        token: String,
        socket_path: PathBuf,
        capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
    ) -> Self {
        Self {
            token,
            socket_path,
            pid: process_id(),
            started_at: utc_now(),
            token_path: state::auth_token_path().display().to_string(),
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

    fn handle(&self, envelope: BridgeEnvelope) -> BridgeResponse {
        if envelope.token != self.token {
            let error = CliError::from(CliErrorKind::workflow_io("bridge token mismatch"));
            return BridgeResponse::error(&error);
        }
        match self.handle_authorized(envelope.request) {
            Ok(response) => response,
            Err(error) => BridgeResponse::error(&error),
        }
    }

    fn handle_authorized(&self, request: BridgeRequest) -> Result<BridgeResponse, CliError> {
        match request {
            BridgeRequest::Status => BridgeResponse::ok_payload(&BridgeStatusReport {
                running: true,
                socket_path: Some(self.socket_path.display().to_string()),
                pid: Some(self.pid),
                started_at: Some(self.started_at.clone()),
                uptime_seconds: uptime_from_started_at(&self.started_at),
                capabilities: self.capabilities()?.clone(),
            }),
            BridgeRequest::Shutdown => {
                self.shutdown.store(true, Ordering::SeqCst);
                Ok(BridgeResponse::empty_ok())
            }
            BridgeRequest::Capability {
                capability,
                action,
                payload,
            } => self.handle_capability(&capability, &action, payload),
        }
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
                let spec: AgentTuiBridgeStartSpec = parse_bridge_payload(payload)?;
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

    fn start_agent_tui(&self, spec: AgentTuiBridgeStartSpec) -> Result<AgentTuiSnapshot, CliError> {
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
}

#[derive(Debug, Clone)]
pub struct BridgeClient {
    socket_path: PathBuf,
    token: String,
}

impl BridgeClient {
    /// Build a bridge client from the persisted running bridge state.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge is unavailable or the auth token
    /// cannot be loaded.
    pub fn from_state_file() -> Result<Self, CliError> {
        let state = load_running_bridge_state()?.ok_or_else(|| {
            CliErrorKind::sandbox_feature_disabled(BridgeCapability::AgentTui.sandbox_feature())
        })?;
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
            socket_path: PathBuf::from(state.socket_path),
            token,
        })
    }

    /// Build a bridge client for one required capability.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge is unavailable, the capability is
    /// not enabled, or the auth token cannot be loaded.
    pub fn for_capability(capability: BridgeCapability) -> Result<Self, CliError> {
        let state = load_running_bridge_state()?
            .ok_or_else(|| CliErrorKind::sandbox_feature_disabled(capability.sandbox_feature()))?;
        if !state.capabilities.contains_key(capability.name()) {
            return Err(
                CliErrorKind::sandbox_feature_disabled(capability.sandbox_feature()).into(),
            );
        }
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
            socket_path: PathBuf::from(state.socket_path),
            token,
        })
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

    /// Start one bridge-managed agent TUI session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be encoded or decoded.
    pub fn agent_tui_start(
        &self,
        spec: &AgentTuiBridgeStartSpec,
    ) -> Result<AgentTuiSnapshot, CliError> {
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
    PathBuf::from("/tmp").join(format!(
        "{FALLBACK_BRIDGE_SOCKET_PREFIX}{}{FALLBACK_BRIDGE_SOCKET_SUFFIX}",
        &digest[..16]
    ))
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

fn write_bridge_state(state: &BridgeState) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
    write_json_pretty(&bridge_state_path(), state)
}

fn clear_bridge_state() -> Result<(), CliError> {
    let socket_path = read_bridge_state()?
        .map_or_else(bridge_socket_path, |state| PathBuf::from(state.socket_path));
    remove_if_exists(&bridge_state_path())?;
    remove_if_exists(&socket_path)?;
    Ok(())
}

/// Load the bridge state only when the recorded PID is still alive.
///
/// # Errors
/// Returns [`CliError`] when the state cannot be read or stale files cannot be
/// cleaned up.
pub fn load_running_bridge_state() -> Result<Option<BridgeState>, CliError> {
    let Some(state) = read_bridge_state()? else {
        return Ok(None);
    };
    if pid_alive(state.pid) {
        return Ok(Some(state));
    }
    clear_bridge_state()?;
    Ok(None)
}

/// Build the daemon manifest view of the unified host bridge.
///
/// # Errors
/// Returns [`CliError`] when the persisted bridge state cannot be read.
pub fn host_bridge_manifest() -> Result<HostBridgeManifest, CliError> {
    let Some(state) = load_running_bridge_state()? else {
        return Ok(HostBridgeManifest::default());
    };
    Ok(HostBridgeManifest {
        running: true,
        socket_path: Some(state.socket_path),
        capabilities: state.capabilities,
    })
}

/// Return the live `codex` capability manifest, if present.
///
/// # Errors
/// Returns [`CliError`] when the bridge state cannot be read.
pub fn running_codex_capability() -> Result<Option<HostBridgeCapabilityManifest>, CliError> {
    let Some(state) = load_running_bridge_state()? else {
        return Ok(None);
    };
    Ok(state.capabilities.get(BRIDGE_CAPABILITY_CODEX).cloned())
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
    let Some(state) = load_running_bridge_state()? else {
        return Ok(BridgeStatusReport::not_running());
    };
    Ok(BridgeStatusReport {
        running: true,
        socket_path: Some(state.socket_path),
        pid: Some(state.pid),
        started_at: Some(state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&state.started_at),
        capabilities: state.capabilities,
    })
}

/// Stop the running bridge and clean up its persisted state.
///
/// # Errors
/// Returns [`CliError`] when the bridge cannot be contacted or its state files
/// cannot be removed.
pub fn stop_bridge() -> Result<BridgeStatusReport, CliError> {
    let Some(state) = read_bridge_state()? else {
        clear_bridge_state()?;
        return Ok(BridgeStatusReport::not_running());
    };
    if pid_alive(state.pid) {
        let token = fs::read_to_string(&state.token_path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "read bridge token {}: {error}",
                    state.token_path
                ))
            })?
            .trim()
            .to_string();
        let client = BridgeClient {
            socket_path: PathBuf::from(&state.socket_path),
            token,
        };
        let _ = client.shutdown();
        wait_until_dead(state.pid, STOP_GRACE_PERIOD)?;
    }
    clear_bridge_state()?;
    Ok(BridgeStatusReport {
        running: false,
        socket_path: Some(state.socket_path),
        pid: Some(state.pid),
        started_at: Some(state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&state.started_at),
        capabilities: state.capabilities,
    })
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

fn apply_bridge_state_to_manifest() {
    let Some(mut manifest) = bridge_manifest_update() else {
        return;
    };
    let Some(host_bridge) = bridge_host_manifest_update() else {
        return;
    };
    if manifest.host_bridge == host_bridge {
        return;
    }
    manifest.host_bridge = host_bridge;
    publish_bridge_manifest_update(&manifest);
}

fn bridge_manifest_update() -> Option<state::DaemonManifest> {
    state::load_manifest().ok().flatten()
}

fn bridge_host_manifest_update() -> Option<HostBridgeManifest> {
    host_bridge_manifest().ok()
}

fn write_bridge_manifest_update(manifest: &state::DaemonManifest) -> Result<(), CliError> {
    state::write_manifest(manifest)
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
    let Some(state) = load_running_bridge_state()? else {
        return Ok(false);
    };
    if state.socket_path != config.socket_path.display().to_string() {
        return Ok(false);
    }
    let running_capabilities: BTreeSet<&str> =
        state.capabilities.keys().map(String::as_str).collect();
    let requested_capabilities: BTreeSet<&str> = config
        .capabilities
        .iter()
        .map(|capability| capability.name())
        .collect();
    if running_capabilities != requested_capabilities {
        return Ok(false);
    }
    if let Some(codex_binary) = config.codex_binary.as_ref()
        && let Some(codex) = state.capabilities.get(BRIDGE_CAPABILITY_CODEX)
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

fn run_bridge_server(config: &ResolvedBridgeConfig) -> Result<i32, CliError> {
    state::ensure_daemon_dirs()?;
    remove_if_exists(&config.socket_path)?;
    let listener = UnixListener::bind(&config.socket_path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "bind bridge socket {}: {error}",
            config.socket_path.display()
        ))
    })?;
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
        capabilities,
    ));
    if config.capabilities.contains(&BridgeCapability::Codex)
        && let Some(codex_binary) = config.codex_binary.as_ref()
    {
        let process = spawn_codex_process(codex_binary, config.codex_port)?;
        server.set_codex_process(process)?;
        spawn_codex_monitor(Arc::clone(&server));
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
    Ok(0)
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

fn handle_stream(server: &BridgeServer, stream: UnixStream) -> Result<(), CliError> {
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
    command.arg("bridge").arg("start");
    for capability in &config.capabilities {
        command.arg("--capability").arg(capability.name());
    }
    command.arg("--socket-path").arg(&config.socket_path);
    if config.capabilities.contains(&BridgeCapability::Codex) {
        command
            .arg("--codex-port")
            .arg(config.codex_port.to_string());
        if let Some(codex_binary) = config.codex_binary.as_ref() {
            command.arg("--codex-path").arg(codex_binary);
        }
    }
    let child = command
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn bridge: {error}")))?;
    println!("bridge started in background (pid {})", child.id());
    Ok(0)
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
    CliErrorKind::workflow_io(format!(
        "bridge error {}: {}",
        response.code.unwrap_or_else(|| "UNKNOWN".to_string()),
        response
            .message
            .unwrap_or_else(|| "unknown bridge error".to_string())
    ))
    .into()
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

fn render_launch_agent_plist(harness_binary: &Path, config: &ResolvedBridgeConfig) -> String {
    let mut args = vec![
        format!("<string>{}</string>", harness_binary.display()),
        "<string>bridge</string>".to_string(),
        "<string>start</string>".to_string(),
    ];
    for capability in &config.capabilities {
        args.push("<string>--capability</string>".to_string());
        args.push(format!("<string>{}</string>", capability.name()));
    }
    args.push("<string>--socket-path</string>".to_string());
    args.push(format!("<string>{}</string>", config.socket_path.display()));
    if config.capabilities.contains(&BridgeCapability::Codex) {
        args.push("<string>--codex-port</string>".to_string());
        args.push(format!("<string>{}</string>", config.codex_port));
        if let Some(binary) = config.codex_binary.as_ref() {
            args.push("<string>--codex-path</string>".to_string());
            args.push(format!("<string>{}</string>", binary.display()));
        }
    }
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
        let args = BridgeConfigArgs {
            capabilities: Vec::new(),
            socket_path: None,
            codex_port: None,
            codex_path: None,
        };
        let selected = args.selected_capabilities();
        assert_eq!(selected, compiled_capabilities());
    }

    #[test]
    fn config_honors_explicit_capability_subset() {
        let args = BridgeConfigArgs {
            capabilities: vec![BridgeCapability::AgentTui],
            socket_path: None,
            codex_port: None,
            codex_path: None,
        };
        let selected = args.selected_capabilities();
        assert_eq!(selected, BTreeSet::from([BridgeCapability::AgentTui]),);
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
    fn bridge_socket_path_falls_back_for_long_root() {
        let tmp = tempdir().expect("tempdir");
        let long_root = tmp.path().join(
            "very/long/path/for/a/daemon/root/that/would/overflow/the/unix/socket/path/limit/on/macos",
        );
        let path = bridge_socket_path_for_root(&long_root);
        assert!(path.starts_with("/tmp"));
        assert!(unix_socket_path_fits(&path));
    }
}
