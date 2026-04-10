use std::collections::BTreeMap;
use std::env::{current_exe, var};
use std::fs::File;
use std::fs::Permissions;
use std::io::{BufRead, BufReader, ErrorKind, Write as _};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio, id as process_id};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use clap::{Args, Subcommand};
use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::workspace::utc_now;

use super::agent_tui::{
    AgentTuiInputRequest, AgentTuiLaunchProfile, AgentTuiProcess, AgentTuiResizeRequest,
    AgentTuiSize, AgentTuiSnapshot, AgentTuiSnapshotContext, AgentTuiStatus, send_initial_prompt,
    snapshot_from_process, spawn_agent_tui_process,
};
use super::{codex_bridge, state};

pub const AGENT_TUI_BRIDGE_LAUNCH_AGENT_LABEL: &str = "io.harness.agent-tui-bridge";
const STOP_GRACE_PERIOD: Duration = Duration::from_secs(5);
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiBridgeState {
    pub socket_path: String,
    pub pid: u32,
    pub started_at: String,
    pub token_path: String,
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

#[must_use]
pub fn bridge_state_path() -> PathBuf {
    state::daemon_root().join("agent-tui-bridge.json")
}

#[must_use]
pub fn bridge_socket_path() -> PathBuf {
    state::daemon_root().join("agent-tui-bridge.sock")
}

/// Load the published host-bridge state if one has been registered.
///
/// # Errors
/// Returns a workflow I/O or parse error when the state file exists but cannot
/// be decoded.
pub fn read_bridge_state() -> Result<Option<AgentTuiBridgeState>, CliError> {
    read_bridge_state_at(&bridge_state_path())
}

fn read_bridge_state_at(path: &Path) -> Result<Option<AgentTuiBridgeState>, CliError> {
    if !path.is_file() {
        return Ok(None);
    }
    read_json_typed(path).map(Some)
}

fn write_bridge_state(state: &AgentTuiBridgeState) -> Result<(), CliError> {
    super::state::ensure_daemon_dirs()?;
    write_bridge_state_at(&bridge_state_path(), state)
}

fn write_bridge_state_at(path: &Path, state: &AgentTuiBridgeState) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "create agent TUI bridge state dir {}: {error}",
                parent.display()
            ))
        })?;
    }
    write_json_pretty(path, state)
}

fn clear_bridge_state() -> Result<(), CliError> {
    clear_bridge_state_paths(&bridge_state_path(), &bridge_socket_path())
}

fn clear_bridge_state_paths(state_path: &Path, socket_path: &Path) -> Result<(), CliError> {
    remove_if_exists(state_path)?;
    remove_if_exists(socket_path)?;
    Ok(())
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

#[derive(Debug, Clone)]
pub struct AgentTuiBridgeClient {
    socket_path: PathBuf,
    token: String,
}

impl AgentTuiBridgeClient {
    /// Construct a client from the published bridge state on disk.
    ///
    /// # Errors
    /// Returns `SANDBOX001` when the host bridge is unavailable, or a workflow
    /// error when the state, token, or PID health checks fail.
    pub fn from_state_file() -> Result<Self, CliError> {
        Self::from_state_path(&bridge_state_path())
    }

    fn from_state_path(state_path: &Path) -> Result<Self, CliError> {
        let state = read_bridge_state_at(state_path)?
            .ok_or_else(|| CliErrorKind::sandbox_feature_disabled("agent-tui.host-bridge"))?;
        if !codex_bridge::pid_alive(state.pid) {
            return Err(CliErrorKind::workflow_io(format!(
                "agent TUI host bridge is not running (stale pid {})",
                state.pid
            ))
            .into());
        }
        let token = fs::read_to_string(&state.token_path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "read agent TUI bridge token {}: {error}",
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

    #[must_use]
    pub fn new(socket_path: PathBuf, token: String) -> Self {
        Self { socket_path, token }
    }

    /// Start a new PTY-backed agent TUI through the host bridge.
    ///
    /// # Errors
    /// Returns a workflow error when the socket round trip or PTY spawn fails.
    pub fn start(&self, spec: &AgentTuiBridgeStartSpec) -> Result<AgentTuiSnapshot, CliError> {
        self.snapshot_request(AgentTuiBridgeRequest::Start { spec: spec.clone() })
    }

    /// Fetch the latest terminal snapshot for an active bridged TUI.
    ///
    /// # Errors
    /// Returns a workflow error when the socket request fails or the TUI is no
    /// longer active.
    pub fn get(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.snapshot_request(AgentTuiBridgeRequest::Get {
            tui_id: tui_id.to_string(),
        })
    }

    /// Send keyboard-like input to a bridged TUI and return the refreshed
    /// snapshot.
    ///
    /// # Errors
    /// Returns a workflow error when the socket request fails or input cannot
    /// be applied.
    pub fn input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.snapshot_request(AgentTuiBridgeRequest::Input {
            tui_id: tui_id.to_string(),
            request: request.clone(),
        })
    }

    /// Resize a bridged PTY and return the refreshed screen snapshot.
    ///
    /// # Errors
    /// Returns a workflow error when the resize request fails.
    pub fn resize(
        &self,
        tui_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.snapshot_request(AgentTuiBridgeRequest::Resize {
            tui_id: tui_id.to_string(),
            request: *request,
        })
    }

    /// Stop a bridged PTY session and return the terminal snapshot captured at
    /// shutdown.
    ///
    /// # Errors
    /// Returns a workflow error when the stop request fails.
    pub fn stop(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.snapshot_request(AgentTuiBridgeRequest::Stop {
            tui_id: tui_id.to_string(),
        })
    }

    /// Ask the host bridge server to shut down.
    ///
    /// # Errors
    /// Returns a workflow error when the request fails or the bridge rejects
    /// the shutdown.
    pub fn shutdown(&self) -> Result<(), CliError> {
        let response = self.send(AgentTuiBridgeRequest::Shutdown)?;
        if response.ok {
            return Ok(());
        }
        Err(bridge_response_error(response))
    }

    fn snapshot_request(
        &self,
        request: AgentTuiBridgeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let response = self.send(request)?;
        if response.ok {
            return response.snapshot.ok_or_else(|| {
                CliErrorKind::workflow_io("agent TUI bridge response omitted snapshot").into()
            });
        }
        Err(bridge_response_error(response))
    }

    fn send(&self, request: AgentTuiBridgeRequest) -> Result<AgentTuiBridgeResponse, CliError> {
        let envelope = AgentTuiBridgeEnvelope {
            token: self.token.clone(),
            request,
        };
        let mut stream = UnixStream::connect(&self.socket_path).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "connect agent TUI bridge {}: {error}",
                self.socket_path.display()
            ))
        })?;
        let payload = serde_json::to_string(&envelope).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("serialize agent TUI bridge request: {error}"))
        })?;
        stream
            .write_all(payload.as_bytes())
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("write agent TUI bridge request: {error}"))
            })?;

        let mut line = String::new();
        BufReader::new(stream)
            .read_line(&mut line)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("read agent TUI bridge response: {error}"))
            })?;
        serde_json::from_str(&line).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse agent TUI bridge response: {error}")).into()
        })
    }
}

fn bridge_response_error(response: AgentTuiBridgeResponse) -> CliError {
    CliErrorKind::workflow_io(format!(
        "agent TUI bridge error {}: {}",
        response.code.unwrap_or_else(|| "UNKNOWN".to_string()),
        response
            .message
            .unwrap_or_else(|| "unknown bridge error".to_string())
    ))
    .into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AgentTuiBridgeEnvelope {
    token: String,
    request: AgentTuiBridgeRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum AgentTuiBridgeRequest {
    Start {
        spec: AgentTuiBridgeStartSpec,
    },
    Get {
        tui_id: String,
    },
    Input {
        tui_id: String,
        request: AgentTuiInputRequest,
    },
    Resize {
        tui_id: String,
        request: AgentTuiResizeRequest,
    },
    Stop {
        tui_id: String,
    },
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AgentTuiBridgeResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    snapshot: Option<AgentTuiSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

impl AgentTuiBridgeResponse {
    fn ok(snapshot: AgentTuiSnapshot) -> Self {
        Self {
            ok: true,
            snapshot: Some(snapshot),
            code: None,
            message: None,
        }
    }

    const fn empty_ok() -> Self {
        Self {
            ok: true,
            snapshot: None,
            code: None,
            message: None,
        }
    }

    fn error(error: &CliError) -> Self {
        Self {
            ok: false,
            snapshot: None,
            code: Some(error.code().to_string()),
            message: Some(error.to_string()),
        }
    }
}

#[derive(Clone)]
struct BridgeActiveTui {
    process: Arc<AgentTuiProcess>,
    context: BridgeSnapshotContext,
    created_at: String,
}

#[derive(Clone)]
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

struct AgentTuiBridgeServer {
    token: String,
    active: Mutex<BTreeMap<String, BridgeActiveTui>>,
    shutdown: AtomicBool,
}

impl AgentTuiBridgeServer {
    fn new(token: String) -> Self {
        Self {
            token,
            active: Mutex::new(BTreeMap::new()),
            shutdown: AtomicBool::new(false),
        }
    }

    fn handle(&self, envelope: AgentTuiBridgeEnvelope) -> AgentTuiBridgeResponse {
        if envelope.token != self.token {
            let error =
                CliError::from(CliErrorKind::workflow_io("agent TUI bridge token mismatch"));
            return AgentTuiBridgeResponse::error(&error);
        }
        match self.handle_authorized(envelope.request) {
            Ok(response) => response,
            Err(error) => AgentTuiBridgeResponse::error(&error),
        }
    }

    fn handle_authorized(
        &self,
        request: AgentTuiBridgeRequest,
    ) -> Result<AgentTuiBridgeResponse, CliError> {
        match request {
            AgentTuiBridgeRequest::Start { spec } => {
                self.start(spec).map(AgentTuiBridgeResponse::ok)
            }
            AgentTuiBridgeRequest::Get { tui_id } => {
                self.get(&tui_id).map(AgentTuiBridgeResponse::ok)
            }
            AgentTuiBridgeRequest::Input { tui_id, request } => {
                let process = self.active_tui(&tui_id)?.process;
                process.send_input(&request.input)?;
                self.get(&tui_id).map(AgentTuiBridgeResponse::ok)
            }
            AgentTuiBridgeRequest::Resize { tui_id, request } => {
                let process = self.active_tui(&tui_id)?.process;
                process.resize(request.size()?)?;
                self.get(&tui_id).map(AgentTuiBridgeResponse::ok)
            }
            AgentTuiBridgeRequest::Stop { tui_id } => {
                self.stop(&tui_id).map(AgentTuiBridgeResponse::ok)
            }
            AgentTuiBridgeRequest::Shutdown => {
                self.shutdown.store(true, Ordering::SeqCst);
                Ok(AgentTuiBridgeResponse::empty_ok())
            }
        }
    }

    fn start(&self, spec: AgentTuiBridgeStartSpec) -> Result<AgentTuiSnapshot, CliError> {
        if self.active_map()?.contains_key(&spec.tui_id) {
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
        self.active_map()?.insert(
            spec.tui_id,
            BridgeActiveTui {
                process,
                context,
                created_at: snapshot.created_at.clone(),
            },
        );
        Ok(snapshot)
    }

    fn get(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tui(tui_id)?;
        let mut status = AgentTuiStatus::Running;
        let mut exit_code = None;
        let mut signal = None;
        if let Some(exit_status) = active.process.try_wait()? {
            status = AgentTuiStatus::Exited;
            exit_code = Some(exit_status.exit_code());
            signal = exit_status.signal().map(ToString::to_string);
            let _ = self.active_map()?.remove(tui_id);
        }
        let mut snapshot =
            snapshot_from_process(&active.context.borrowed(), &active.process, status)?;
        snapshot.created_at = active.created_at;
        snapshot.exit_code = exit_code;
        snapshot.signal = signal;
        Ok(snapshot)
    }

    fn stop(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_map()?.remove(tui_id).ok_or_else(|| {
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
        Ok(snapshot)
    }

    fn active_tui(&self, tui_id: &str) -> Result<BridgeActiveTui, CliError> {
        self.active_map()?.get(tui_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "agent TUI '{tui_id}' is not active in host bridge"
            ))
            .into()
        })
    }

    fn active_map(&self) -> Result<MutexGuard<'_, BTreeMap<String, BridgeActiveTui>>, CliError> {
        self.active.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("agent TUI bridge active map poisoned: {error}"))
                .into()
        })
    }
}

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AgentTuiBridgeCommand {
    Start(AgentTuiBridgeStartArgs),
    Stop(AgentTuiBridgeStopArgs),
    Status(AgentTuiBridgeStatusArgs),
    InstallLaunchAgent(AgentTuiBridgeInstallLaunchAgentArgs),
    RemoveLaunchAgent(AgentTuiBridgeRemoveLaunchAgentArgs),
}

#[derive(Debug, Clone, Args)]
pub struct AgentTuiBridgeStartArgs {
    #[arg(long, value_name = "PATH")]
    pub socket_path: Option<PathBuf>,
    #[arg(long)]
    pub daemon: bool,
}

#[derive(Debug, Clone, Args)]
pub struct AgentTuiBridgeStopArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct AgentTuiBridgeStatusArgs {
    #[arg(long)]
    pub plain: bool,
}

#[derive(Debug, Clone, Args)]
pub struct AgentTuiBridgeInstallLaunchAgentArgs {}

#[derive(Debug, Clone, Args)]
pub struct AgentTuiBridgeRemoveLaunchAgentArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentTuiBridgeStatusReport {
    pub running: bool,
    pub socket_path: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<String>,
    pub uptime_seconds: Option<u64>,
}

impl AgentTuiBridgeStatusReport {
    const fn not_running() -> Self {
        Self {
            running: false,
            socket_path: None,
            pid: None,
            started_at: None,
            uptime_seconds: None,
        }
    }
}

impl Execute for AgentTuiBridgeCommand {
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

impl Execute for AgentTuiBridgeStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        codex_bridge::ensure_host_context("agent-tui-bridge-start")?;
        let socket_path = self.socket_path.clone().unwrap_or_else(bridge_socket_path);
        if self.daemon {
            return start_detached(&socket_path);
        }
        let token = state::ensure_auth_token()?;
        run_bridge_server(&socket_path, &token)
    }
}

impl Execute for AgentTuiBridgeStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let report = stop_bridge()?;
        if self.json {
            print_json(&report)?;
        } else {
            print_status_plain(&report);
        }
        Ok(0)
    }
}

impl Execute for AgentTuiBridgeStatusArgs {
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

impl Execute for AgentTuiBridgeInstallLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        codex_bridge::ensure_host_context("agent-tui-bridge-install-launch-agent")?;
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
            best_effort_bootout();
            bootstrap_agent(&plist_path)?;
        }
        println!("installed {}", plist_path.display());
        Ok(0)
    }
}

impl Execute for AgentTuiBridgeRemoveLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        codex_bridge::ensure_host_context("agent-tui-bridge-remove-launch-agent")?;
        let plist_path = launch_agent_plist_path()?;
        let existed = plist_path.is_file();
        if existed && cfg!(target_os = "macos") {
            best_effort_bootout();
        }
        if existed {
            fs::remove_file(&plist_path).map_err(|error| {
                CliErrorKind::workflow_io(format!("remove agent TUI bridge plist: {error}"))
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

fn run_bridge_server(socket_path: &Path, token: &str) -> Result<i32, CliError> {
    run_bridge_server_inner(socket_path, token, true)
}

fn run_bridge_server_inner(
    socket_path: &Path,
    token: &str,
    publish_state: bool,
) -> Result<i32, CliError> {
    if publish_state {
        state::ensure_daemon_dirs()?;
    } else if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "create agent TUI bridge socket dir {}: {error}",
                parent.display()
            ))
        })?;
    }
    remove_if_exists(socket_path)?;
    let listener = UnixListener::bind(socket_path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "bind agent TUI bridge socket {}: {error}",
            socket_path.display()
        ))
    })?;
    fs::set_permissions(socket_path, Permissions::from_mode(0o600)).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "set agent TUI bridge socket permissions {}: {error}",
            socket_path.display()
        ))
    })?;
    if publish_state {
        write_bridge_state(&AgentTuiBridgeState {
            socket_path: socket_path.display().to_string(),
            pid: process_id(),
            started_at: utc_now(),
            token_path: state::auth_token_path().display().to_string(),
        })?;
    }

    let server = AgentTuiBridgeServer::new(token.to_string());
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle_stream(&server, stream)?,
            Err(error) => {
                return Err(CliErrorKind::workflow_io(format!(
                    "accept agent TUI bridge connection: {error}"
                ))
                .into());
            }
        }
        if server.shutdown.load(Ordering::SeqCst) {
            break;
        }
    }
    if publish_state {
        clear_bridge_state()?;
    } else {
        remove_if_exists(socket_path)?;
    }
    Ok(0)
}

fn handle_stream(server: &AgentTuiBridgeServer, stream: UnixStream) -> Result<(), CliError> {
    let mut line = String::new();
    BufReader::new(stream.try_clone().map_err(|error| {
        CliErrorKind::workflow_io(format!("clone agent TUI bridge stream: {error}"))
    })?)
    .read_line(&mut line)
    .map_err(|error| {
        CliErrorKind::workflow_io(format!("read agent TUI bridge request: {error}"))
    })?;
    let response = match serde_json::from_str::<AgentTuiBridgeEnvelope>(&line) {
        Ok(envelope) => server.handle(envelope),
        Err(error) => {
            let error = CliError::from(CliErrorKind::workflow_parse(format!(
                "parse agent TUI bridge request: {error}"
            )));
            AgentTuiBridgeResponse::error(&error)
        }
    };
    let payload = serde_json::to_string(&response).map_err(|error| {
        CliErrorKind::workflow_serialize(format!("serialize agent TUI bridge response: {error}"))
    })?;
    let mut writer = stream;
    writer
        .write_all(payload.as_bytes())
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("write agent TUI bridge response: {error}")).into()
        })
}

/// Read the current published bridge status.
///
/// # Errors
/// Returns a workflow error when the bridge state file exists but cannot be
/// decoded.
pub fn status_report() -> Result<AgentTuiBridgeStatusReport, CliError> {
    status_report_from_state_path(&bridge_state_path())
}

fn status_report_from_state_path(
    state_path: &Path,
) -> Result<AgentTuiBridgeStatusReport, CliError> {
    let Some(state) = read_bridge_state_at(state_path)? else {
        return Ok(AgentTuiBridgeStatusReport::not_running());
    };
    let running = codex_bridge::pid_alive(state.pid);
    Ok(AgentTuiBridgeStatusReport {
        running,
        socket_path: Some(state.socket_path),
        pid: Some(state.pid),
        started_at: Some(state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&state.started_at),
    })
}

/// Stop the published bridge server if it is running and clear its state file.
///
/// # Errors
/// Returns a workflow error when the token cannot be read or the bridge refuses
/// to shut down cleanly.
pub fn stop_bridge() -> Result<AgentTuiBridgeStatusReport, CliError> {
    stop_bridge_with_paths(&bridge_state_path(), &bridge_socket_path())
}

fn stop_bridge_with_paths(
    state_path: &Path,
    socket_path: &Path,
) -> Result<AgentTuiBridgeStatusReport, CliError> {
    let Some(state) = read_bridge_state_at(state_path)? else {
        clear_bridge_state_paths(state_path, socket_path)?;
        return Ok(AgentTuiBridgeStatusReport::not_running());
    };
    if codex_bridge::pid_alive(state.pid) {
        let token = fs::read_to_string(&state.token_path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "read agent TUI bridge token {}: {error}",
                    state.token_path
                ))
            })?
            .trim()
            .to_string();
        let client = AgentTuiBridgeClient::new(PathBuf::from(&state.socket_path), token);
        let _ = client.shutdown();
        wait_until_dead(state.pid, STOP_GRACE_PERIOD)?;
    }
    clear_bridge_state_paths(state_path, socket_path)?;
    Ok(AgentTuiBridgeStatusReport {
        running: false,
        socket_path: Some(state.socket_path),
        pid: Some(state.pid),
        started_at: Some(state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&state.started_at),
    })
}

fn start_detached(socket_path: &Path) -> Result<i32, CliError> {
    let harness = current_exe().map_err(|error| {
        CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
    })?;
    state::ensure_daemon_dirs()?;
    let stdout_path = state::daemon_root().join("agent-tui-bridge.stdout.log");
    let stderr_path = state::daemon_root().join("agent-tui-bridge.stderr.log");
    let stdout = File::create(&stdout_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("create {}: {error}", stdout_path.display()))
    })?;
    let stderr = File::create(&stderr_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("create {}: {error}", stderr_path.display()))
    })?;
    let child = Command::new(&harness)
        .args([
            "agent-tui-bridge",
            "start",
            "--socket-path",
            &socket_path.display().to_string(),
        ])
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn agent TUI bridge: {error}")))?;
    println!(
        "agent-tui-bridge started in background (pid {})",
        child.id()
    );
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
        "agent TUI bridge stop: pid {pid} still alive after {}s",
        grace.as_secs()
    ))
    .into())
}

fn wait_until_pid_dead(pid: u32, grace: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < grace {
        if pid_terminated(pid) {
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
    if status.success() || !codex_bridge::pid_alive(pid) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!("/bin/kill -TERM {pid} exited with {status}")).into())
}

fn pid_terminated(pid: u32) -> bool {
    !codex_bridge::pid_alive(pid) || pid_is_zombie(pid)
}

fn pid_is_zombie(pid: u32) -> bool {
    Command::new("/bin/ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .is_some_and(|state| state.trim().contains('Z'))
}

fn print_json(report: &AgentTuiBridgeStatusReport) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

fn print_status_plain(report: &AgentTuiBridgeStatusReport) {
    if report.running {
        let socket = report.socket_path.as_deref().unwrap_or("?");
        let pid = report
            .pid
            .map_or_else(|| "?".to_string(), |pid| pid.to_string());
        println!("running at {socket} (pid {pid})");
    } else if let Some(socket) = report.socket_path.as_deref() {
        println!("not running (stale socket {socket})");
    } else {
        println!("not running");
    }
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
        .join(format!("{AGENT_TUI_BRIDGE_LAUNCH_AGENT_LABEL}.plist")))
}

fn render_launch_agent_plist(harness_binary: &Path) -> String {
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
    <string>agent-tui-bridge</string>
    <string>start</string>
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
        label = AGENT_TUI_BRIDGE_LAUNCH_AGENT_LABEL,
        binary = harness_binary.display(),
        stdout = state::daemon_root()
            .join("agent-tui-bridge.stdout.log")
            .display(),
        stderr = state::daemon_root()
            .join("agent-tui-bridge.stderr.log")
            .display(),
    )
}

fn launchd_service_target() -> String {
    format!(
        "gui/{}/{AGENT_TUI_BRIDGE_LAUNCH_AGENT_LABEL}",
        uzers::get_current_uid()
    )
}

fn best_effort_bootout() {
    let target = launchd_service_target();
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

#[cfg(test)]
mod tests {
    use super::super::agent_tui::{AgentTuiInput, AgentTuiKey};
    use super::*;
    use tempfile::tempdir;

    /// A PID that is guaranteed not to belong to a live process on macOS.
    /// PID 1 (launchd) is always alive on macOS, so we pick a high number
    /// that no normal system would assign.
    const DEFINITELY_DEAD_PID: u32 = 2_000_000_000;

    fn sample_paths(base: &Path) -> (PathBuf, PathBuf, PathBuf) {
        (
            base.join("agent-tui-bridge.json"),
            base.join("agent-tui-bridge.sock"),
            base.join("auth-token"),
        )
    }

    fn sample_state(token_path: &Path) -> AgentTuiBridgeState {
        AgentTuiBridgeState {
            socket_path: "/tmp/agent-tui-bridge.sock".to_string(),
            pid: DEFINITELY_DEAD_PID,
            started_at: "2026-04-10T12:00:00Z".to_string(),
            token_path: token_path.display().to_string(),
        }
    }

    fn live_state_for_current_process(token_path: &Path) -> AgentTuiBridgeState {
        AgentTuiBridgeState {
            socket_path: "/tmp/agent-tui-bridge.sock".to_string(),
            pid: process_id(),
            started_at: "2026-04-10T12:00:00Z".to_string(),
            token_path: token_path.display().to_string(),
        }
    }

    #[test]
    fn read_bridge_state_returns_none_when_missing() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, _, _) = sample_paths(tmp.path());
        assert!(read_bridge_state_at(&state_path).expect("read").is_none());
    }

    #[test]
    fn write_then_read_roundtrips_bridge_state() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, _, token_path) = sample_paths(tmp.path());
        let state = sample_state(&token_path);
        write_bridge_state_at(&state_path, &state).expect("write");
        let loaded = read_bridge_state_at(&state_path)
            .expect("read")
            .expect("present");
        assert_eq!(loaded, state);
    }

    #[test]
    fn bridge_client_requires_state_file() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, _, _) = sample_paths(tmp.path());
        let error = AgentTuiBridgeClient::from_state_path(&state_path).expect_err("missing state");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.message().contains("agent-tui.host-bridge"));
    }

    #[test]
    fn status_report_returns_not_running_without_state() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, _, _) = sample_paths(tmp.path());
        let report = status_report_from_state_path(&state_path).expect("status");
        assert_eq!(report, AgentTuiBridgeStatusReport::not_running());
    }

    #[test]
    fn status_report_reports_running_when_pid_alive() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, _, token_path) = sample_paths(tmp.path());
        fs::write(&token_path, "token").expect("write token");
        write_bridge_state_at(&state_path, &live_state_for_current_process(&token_path))
            .expect("write state");

        let report = status_report_from_state_path(&state_path).expect("status");
        assert!(report.running);
        assert_eq!(report.pid, Some(process_id()));
        assert_eq!(
            report.socket_path.as_deref(),
            Some("/tmp/agent-tui-bridge.sock")
        );
    }

    #[test]
    fn status_report_reports_stale_state_as_not_running() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, _, token_path) = sample_paths(tmp.path());
        write_bridge_state_at(&state_path, &sample_state(&token_path)).expect("write state");
        let report = status_report_from_state_path(&state_path).expect("status");
        assert!(!report.running);
        assert_eq!(report.pid, Some(DEFINITELY_DEAD_PID));
    }

    #[test]
    fn stop_bridge_is_idempotent_when_state_missing() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, socket_path, _) = sample_paths(tmp.path());
        let report = stop_bridge_with_paths(&state_path, &socket_path).expect("stop");
        assert_eq!(report, AgentTuiBridgeStatusReport::not_running());
        assert!(!state_path.exists());
        assert!(!socket_path.exists());
    }

    #[test]
    fn stop_bridge_clears_stale_state_without_signaling() {
        let tmp = tempdir().expect("tempdir");
        let (state_path, socket_path, token_path) = sample_paths(tmp.path());
        write_bridge_state_at(&state_path, &sample_state(&token_path)).expect("write state");
        let report = stop_bridge_with_paths(&state_path, &socket_path).expect("stop");
        assert!(!report.running);
        assert_eq!(report.pid, Some(DEFINITELY_DEAD_PID));
        assert!(!state_path.exists());
    }

    #[test]
    fn render_launch_agent_plist_contains_expected_fields() {
        let plist = render_launch_agent_plist(Path::new("/usr/local/bin/harness"));
        assert!(plist.contains(AGENT_TUI_BRIDGE_LAUNCH_AGENT_LABEL));
        assert!(plist.contains("agent-tui-bridge"));
        assert!(plist.contains("start"));
        assert!(plist.contains("Aqua"));
        assert!(plist.contains("Interactive"));
        assert!(plist.contains("/usr/local/bin/harness"));
    }

    #[test]
    fn bridge_round_trips_pty_lifecycle_over_socket() {
        let tmp = tempdir().expect("tempdir");
        let socket_path = tmp.path().join("bridge.sock");
        let token = "test-token".to_string();
        let server_token = token.clone();
        let server_socket = socket_path.clone();
        let handle = thread::spawn(move || {
            run_bridge_server_inner(&server_socket, &server_token, false).expect("bridge server")
        });
        wait_for_socket(&socket_path);

        let client = AgentTuiBridgeClient::new(socket_path, token);
        let spec = AgentTuiBridgeStartSpec {
            session_id: "sess-bridge".into(),
            agent_id: "agent-bridge".into(),
            tui_id: "agent-tui-bridge-test".into(),
            profile: AgentTuiLaunchProfile::from_argv(
                "codex",
                vec!["sh".into(), "-c".into(), "cat".into()],
            )
            .expect("profile"),
            project_dir: tmp.path().to_path_buf(),
            transcript_path: tmp.path().join("output.raw"),
            size: AgentTuiSize { rows: 5, cols: 40 },
            prompt: None,
        };
        let started = client.start(&spec).expect("start");
        assert_eq!(started.status, AgentTuiStatus::Running);

        client
            .input(
                &started.tui_id,
                &AgentTuiInputRequest {
                    input: AgentTuiInput::Text {
                        text: "hello bridge".into(),
                    },
                },
            )
            .expect("send text");
        client
            .input(
                &started.tui_id,
                &AgentTuiInputRequest {
                    input: AgentTuiInput::Key {
                        key: AgentTuiKey::Enter,
                    },
                },
            )
            .expect("send enter");
        wait_until(Duration::from_secs(5), || {
            client
                .get(&started.tui_id)
                .expect("get")
                .screen
                .text
                .contains("hello bridge")
        });

        let resized = client
            .resize(
                &started.tui_id,
                &AgentTuiResizeRequest { rows: 8, cols: 30 },
            )
            .expect("resize");
        assert_eq!(resized.size, AgentTuiSize { rows: 8, cols: 30 });

        let stopped = client.stop(&started.tui_id).expect("stop");
        assert_eq!(stopped.status, AgentTuiStatus::Stopped);
        assert!(
            String::from_utf8_lossy(&fs::read(&stopped.transcript_path).expect("transcript"))
                .contains("hello bridge")
        );
        client.shutdown().expect("shutdown");
        assert_eq!(handle.join().expect("join"), 0);
    }

    fn wait_for_socket(socket_path: &Path) {
        wait_until(Duration::from_secs(5), || socket_path.exists());
    }

    fn wait_until(timeout: Duration, mut predicate: impl FnMut() -> bool) {
        let started_at = Instant::now();
        while started_at.elapsed() < timeout {
            if predicate() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        panic!("condition did not become true before timeout");
    }
}
