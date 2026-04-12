#![expect(
    clippy::module_name_repetitions,
    reason = "agent TUI protocol types use an explicit domain prefix"
)]

use std::collections::BTreeMap;
use std::env::{join_paths, split_paths, var_os};
use std::ffi::OsString;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use portable_pty::{Child, CommandBuilder, ExitStatus, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{SessionRole, SessionState};
use crate::workspace::{dirs_home, project_context_dir, utc_now};

use super::bridge::{AgentTuiStartSpec, BridgeCapability, BridgeClient};
use super::db::DaemonDb;
use super::protocol::{SessionJoinRequest, StreamEvent};

const DEFAULT_ROWS: u16 = 30;
const DEFAULT_COLS: u16 = 120;
const LIVE_REFRESH_INTERVAL: Duration = Duration::from_millis(100);
#[cfg(test)]
const DEFAULT_WAIT_TIMEOUT: Duration = Duration::from_secs(5);

type Shared<T> = Arc<Mutex<T>>;

#[derive(Clone)]
struct ActiveAgentTui {
    process: Option<Arc<AgentTuiProcess>>,
    stop_flag: Arc<AtomicBool>,
}

impl ActiveAgentTui {
    fn new(process: Option<Arc<AgentTuiProcess>>) -> Self {
        Self {
            process,
            stop_flag: Arc::new(AtomicBool::new(false)),
        }
    }

    fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }
}

/// Terminal dimensions used when spawning or resizing an agent TUI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiSize {
    pub rows: u16,
    pub cols: u16,
}

impl Default for AgentTuiSize {
    fn default() -> Self {
        Self {
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
        }
    }
}

impl AgentTuiSize {
    /// Validate that the PTY has a usable non-zero size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    pub fn validate(self) -> Result<Self, CliError> {
        if self.rows == 0 || self.cols == 0 {
            return Err(CliErrorKind::workflow_parse(
                "agent TUI rows and cols must be greater than zero",
            )
            .into());
        }
        Ok(self)
    }
}

impl From<AgentTuiSize> for PtySize {
    fn from(size: AgentTuiSize) -> Self {
        Self {
            rows: size.rows,
            cols: size.cols,
            pixel_width: 0,
            pixel_height: 0,
        }
    }
}

/// Runtime-specific command profile for launching an interactive agent CLI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiLaunchProfile {
    pub runtime: String,
    pub argv: Vec<String>,
}

impl AgentTuiLaunchProfile {
    /// Resolve the default launch profile for a supported runtime.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime is unknown.
    pub fn for_runtime(runtime: &str) -> Result<Self, CliError> {
        let runtime = runtime.trim();
        let program = match runtime {
            "codex" => "codex",
            "claude" => "claude",
            "gemini" => "gemini",
            "opencode" => "opencode",
            "copilot" => "copilot",
            "vibe" => "vibe",
            _ => {
                return Err(CliErrorKind::workflow_parse(format!(
                    "unsupported agent TUI runtime '{runtime}'"
                ))
                .into());
            }
        };
        Ok(Self {
            runtime: runtime.to_string(),
            argv: vec![program.to_string()],
        })
    }

    /// Build an explicit launch profile from a structured argv override.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime or argv is empty.
    pub fn from_argv(runtime: &str, argv: Vec<String>) -> Result<Self, CliError> {
        let runtime = runtime.trim();
        if runtime.is_empty() {
            return Err(CliErrorKind::workflow_parse("agent TUI runtime cannot be empty").into());
        }
        let Some(program) = argv.first().map(|value| value.trim()) else {
            return Err(CliErrorKind::workflow_parse("agent TUI argv cannot be empty").into());
        };
        if program.is_empty() {
            return Err(CliErrorKind::workflow_parse("agent TUI argv[0] cannot be empty").into());
        }
        Ok(Self {
            runtime: runtime.to_string(),
            argv,
        })
    }
}

/// Fully resolved process spawn request for a managed agent TUI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTuiSpawnSpec {
    pub profile: AgentTuiLaunchProfile,
    pub project_dir: PathBuf,
    pub env: BTreeMap<String, String>,
    pub size: AgentTuiSize,
}

impl AgentTuiSpawnSpec {
    /// Build a spawn spec and validate the runtime profile and PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when the profile or size is invalid.
    pub fn new(
        profile: AgentTuiLaunchProfile,
        project_dir: PathBuf,
        env: BTreeMap<String, String>,
        size: AgentTuiSize,
    ) -> Result<Self, CliError> {
        AgentTuiLaunchProfile::from_argv(&profile.runtime, profile.argv.clone())?;
        Ok(Self {
            profile,
            project_dir,
            env,
            size: size.validate()?,
        })
    }
}

/// PTY backend boundary used by the TUI manager.
pub trait AgentTuiBackend {
    /// Spawn an interactive agent TUI inside a PTY.
    ///
    /// # Errors
    /// Returns a workflow I/O error if PTY allocation or process spawning fails.
    fn spawn(&self, spec: AgentTuiSpawnSpec) -> Result<AgentTuiProcess, CliError>;
}

/// Cross-platform PTY backend powered by `portable-pty`.
#[derive(Debug, Clone, Copy, Default)]
pub struct PortablePtyAgentTuiBackend;

impl AgentTuiBackend for PortablePtyAgentTuiBackend {
    fn spawn(&self, spec: AgentTuiSpawnSpec) -> Result<AgentTuiProcess, CliError> {
        AgentTuiProcess::spawn(&spec)
    }
}

/// Named keyboard input supported by the headless TUI steering API.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentTuiKey {
    Enter,
    Escape,
    Tab,
    Backspace,
    ArrowUp,
    ArrowDown,
    ArrowRight,
    ArrowLeft,
}

impl AgentTuiKey {
    #[must_use]
    pub const fn bytes(self) -> &'static [u8] {
        match self {
            Self::Enter => b"\r",
            Self::Escape => b"\x1b",
            Self::Tab => b"\t",
            Self::Backspace => b"\x7f",
            Self::ArrowUp => b"\x1b[A",
            Self::ArrowDown => b"\x1b[B",
            Self::ArrowRight => b"\x1b[C",
            Self::ArrowLeft => b"\x1b[D",
        }
    }
}

/// Structured keyboard-like input sent into the PTY master.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentTuiInput {
    Text { text: String },
    Paste { text: String },
    Key { key: AgentTuiKey },
    Control { key: char },
    RawBytesBase64 { data: String },
}

impl AgentTuiInput {
    /// Convert structured input into PTY bytes.
    ///
    /// # Errors
    /// Returns a workflow parse error when control-key or base64 input is invalid.
    pub fn to_bytes(&self) -> Result<Vec<u8>, CliError> {
        match self {
            Self::Text { text } => Ok(text.as_bytes().to_vec()),
            Self::Paste { text } => Ok(bracketed_paste_bytes(text)),
            Self::Key { key } => Ok(key.bytes().to_vec()),
            Self::Control { key } => control_key_bytes(*key),
            Self::RawBytesBase64 { data } => decode_raw_bytes(data),
        }
    }
}

/// Parsed terminal screen state exposed to API and CLI consumers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalScreenSnapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub text: String,
}

impl TerminalScreenSnapshot {
    #[must_use]
    pub const fn size(&self) -> AgentTuiSize {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
    }
}

/// Lifecycle status for a managed agent TUI process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentTuiStatus {
    Starting,
    Running,
    Exited,
    Failed,
    Stopped,
}

impl AgentTuiStatus {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Exited => "exited",
            Self::Failed => "failed",
            Self::Stopped => "stopped",
        }
    }

    pub(crate) fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "starting" => Ok(Self::Starting),
            "running" => Ok(Self::Running),
            "exited" => Ok(Self::Exited),
            "failed" => Ok(Self::Failed),
            "stopped" => Ok(Self::Stopped),
            _ => Err(format!("unknown agent TUI status '{value}'")),
        }
    }
}

/// Request body for starting an agent runtime in an interactive PTY.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiStartRequest {
    pub runtime: String,
    #[serde(default = "default_agent_tui_role")]
    pub role: SessionRole,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub argv: Vec<String>,
    #[serde(default = "default_agent_tui_rows")]
    pub rows: u16,
    #[serde(default = "default_agent_tui_cols")]
    pub cols: u16,
}

impl AgentTuiStartRequest {
    /// Resolve and validate the runtime profile used for PTY spawning.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime or argv is invalid.
    pub fn launch_profile(&self) -> Result<AgentTuiLaunchProfile, CliError> {
        let default_profile = AgentTuiLaunchProfile::for_runtime(&self.runtime)?;
        if self.argv.is_empty() {
            return Ok(default_profile);
        }
        AgentTuiLaunchProfile::from_argv(&default_profile.runtime, self.argv.clone())
    }

    /// Resolve and validate the requested PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    pub fn size(&self) -> Result<AgentTuiSize, CliError> {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
        .validate()
    }
}

/// Request body for sending keyboard-like input into an active agent TUI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiInputRequest {
    pub input: AgentTuiInput,
}

/// Request body for resizing an active agent TUI PTY.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiResizeRequest {
    pub rows: u16,
    pub cols: u16,
}

impl AgentTuiResizeRequest {
    /// Resolve and validate the requested PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    pub fn size(self) -> Result<AgentTuiSize, CliError> {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
        .validate()
    }
}

/// List response for managed agent TUI snapshots.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiListResponse {
    pub tuis: Vec<AgentTuiSnapshot>,
}

/// Persisted, API-facing snapshot for a managed interactive agent runtime.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiSnapshot {
    pub tui_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub runtime: String,
    pub status: AgentTuiStatus,
    pub argv: Vec<String>,
    pub project_dir: String,
    pub size: AgentTuiSize,
    pub screen: TerminalScreenSnapshot,
    pub transcript_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

fn default_agent_tui_role() -> SessionRole {
    SessionRole::Worker
}

const fn default_agent_tui_rows() -> u16 {
    DEFAULT_ROWS
}

const fn default_agent_tui_cols() -> u16 {
    DEFAULT_COLS
}

/// Incremental terminal parser that keeps a `vt100` screen model.
pub struct TerminalScreenParser {
    parser: vt100::Parser,
}

impl TerminalScreenParser {
    #[must_use]
    pub fn new(size: AgentTuiSize) -> Self {
        Self {
            parser: vt100::Parser::new(size.rows, size.cols, 0),
        }
    }

    pub fn process(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
    }

    pub fn resize(&mut self, size: AgentTuiSize) {
        self.parser.screen_mut().set_size(size.rows, size.cols);
    }

    #[must_use]
    pub fn snapshot(&self) -> TerminalScreenSnapshot {
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let (cursor_row, cursor_col) = screen.cursor_position();
        TerminalScreenSnapshot {
            rows,
            cols,
            cursor_row,
            cursor_col,
            text: screen.contents().trim_start_matches('\n').to_string(),
        }
    }
}

/// Daemon-owned manager for interactive agent runtime PTYs.
#[derive(Clone)]
pub struct AgentTuiManagerHandle {
    state: Arc<AgentTuiManagerState>,
}

struct AgentTuiManagerState {
    sender: broadcast::Sender<StreamEvent>,
    db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    active: Mutex<BTreeMap<String, ActiveAgentTui>>,
    sandboxed: bool,
}

impl AgentTuiManagerHandle {
    /// Create a manager bound to the daemon DB and event stream.
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        sandboxed: bool,
    ) -> Self {
        Self {
            state: Arc::new(AgentTuiManagerState {
                sender,
                db,
                active: Mutex::new(BTreeMap::new()),
                sandboxed,
            }),
        }
    }

    /// Start an agent runtime in a PTY and register it in the session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the daemon DB is unavailable, the session cannot be joined,
    /// or PTY/process setup fails.
    pub fn start(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            return self.start_via_bridge(session_id, request);
        }

        let profile = request.launch_profile()?;
        let size = request.size()?;
        let tui_id = format!("agent-tui-{}", Uuid::new_v4());
        let marker_capability = format!("agent-tui:{tui_id}");
        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        let project = resolve_tui_project(&db_guard, session_id, request.project_dir.as_deref())?;
        let joined = super::service::join_session_direct(
            session_id,
            &SessionJoinRequest {
                runtime: profile.runtime.clone(),
                role: request.role,
                capabilities: agent_tui_capabilities(&request.capabilities, &marker_capability),
                name: Some(
                    request
                        .name
                        .clone()
                        .unwrap_or_else(|| format!("{} TUI", profile.runtime)),
                ),
                project_dir: project.project_dir.display().to_string(),
            },
            Some(&db_guard),
        )?;
        let agent_id = agent_id_for_tui(&joined, &marker_capability)?;
        drop(db_guard);

        let transcript_path = transcript_path(&project.context_root, &profile.runtime, &tui_id);
        let snapshot_context = AgentTuiSnapshotContext {
            session_id,
            agent_id: &agent_id,
            tui_id: &tui_id,
            profile: &profile,
            project_dir: &project.project_dir,
            transcript_path: &transcript_path,
        };
        let process = spawn_agent_tui_process(
            session_id,
            &agent_id,
            &tui_id,
            profile.clone(),
            &project.project_dir,
            size,
        )?;

        if let Some(prompt) = request.prompt.as_deref().filter(|value| !value.is_empty())
            && let Err(error) = send_initial_prompt(&process, prompt)
        {
            let _ = process.kill();
            let snapshot = failed_snapshot(&snapshot_context, size, error.to_string());
            let _ = self.save_and_broadcast("agent_tui_failed", &snapshot);
            return Err(error);
        }

        let process = Arc::new(process);
        let snapshot = snapshot_from_process(&snapshot_context, &process, AgentTuiStatus::Running)?;
        let active = ActiveAgentTui::new(Some(Arc::clone(&process)));
        let stop_flag = Arc::clone(&active.stop_flag);
        self.active()?.insert(tui_id.clone(), active);
        if let Err(error) = self.save_and_broadcast("agent_tui_started", &snapshot) {
            let _ = self.remove_active(&tui_id)?;
            return Err(error);
        }
        self.spawn_live_refresh(tui_id, stop_flag);
        Ok(snapshot)
    }

    fn start_via_bridge(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let profile = request.launch_profile()?;
        let size = request.size()?;
        let tui_id = format!("agent-tui-{}", Uuid::new_v4());
        let marker_capability = format!("agent-tui:{tui_id}");
        let bridge = BridgeClient::for_capability(BridgeCapability::AgentTui)?;
        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        let project = resolve_tui_project(&db_guard, session_id, request.project_dir.as_deref())?;
        let joined = super::service::join_session_direct(
            session_id,
            &SessionJoinRequest {
                runtime: profile.runtime.clone(),
                role: request.role,
                capabilities: agent_tui_capabilities(&request.capabilities, &marker_capability),
                name: Some(
                    request
                        .name
                        .clone()
                        .unwrap_or_else(|| format!("{} TUI", profile.runtime)),
                ),
                project_dir: project.project_dir.display().to_string(),
            },
            Some(&db_guard),
        )?;
        let agent_id = agent_id_for_tui(&joined, &marker_capability)?;
        drop(db_guard);

        let transcript_path = transcript_path(&project.context_root, &profile.runtime, &tui_id);
        let snapshot = bridge.agent_tui_start(&AgentTuiStartSpec {
            session_id: session_id.to_string(),
            agent_id,
            tui_id,
            profile,
            project_dir: project.project_dir,
            transcript_path,
            size,
            prompt: request.prompt.clone(),
        })?;
        let active = ActiveAgentTui::new(None);
        let stop_flag = Arc::clone(&active.stop_flag);
        self.active()?.insert(snapshot.tui_id.clone(), active);
        if let Err(error) = self.save_and_broadcast("agent_tui_started", &snapshot) {
            let _ = self.remove_active(&snapshot.tui_id)?;
            return Err(error);
        }
        self.spawn_live_refresh(snapshot.tui_id.clone(), stop_flag);
        Ok(snapshot)
    }

    /// List managed TUI snapshots for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] when DB access fails.
    pub fn list(&self, session_id: &str) -> Result<AgentTuiListResponse, CliError> {
        let db = self.db()?;
        let db_guard = lock_db(&db)?;
        let mut tuis = db_guard.list_agent_tuis(session_id)?;
        let roles_by_agent = db_guard
            .resolve_session(session_id)?
            .map(|resolved| {
                resolved
                    .state
                    .agents
                    .into_iter()
                    .map(|(agent_id, agent)| (agent_id, agent.role))
                    .collect()
            })
            .unwrap_or_default();
        super::ordering::sort_agent_tui_snapshots(&mut tuis, &roles_by_agent);
        Ok(AgentTuiListResponse { tuis })
    }

    /// Load a managed TUI snapshot by ID, refreshing live screen/process state when active.
    ///
    /// # Errors
    /// Returns [`CliError`] when DB access fails or the TUI is missing.
    pub fn get(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let previous = self.load_snapshot(tui_id)?;
        let refreshed = self.refresh_live_snapshot(previous.clone())?;
        self.persist_refreshed_snapshot(&previous, &refreshed)?;
        Ok(refreshed)
    }

    /// Send keyboard-like input into an active TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is inactive or input/write fails.
    pub fn input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            let snapshot = BridgeClient::for_capability(BridgeCapability::AgentTui)?
                .agent_tui_input(tui_id, request)?;
            self.save_and_broadcast("agent_tui_updated", &snapshot)?;
            return Ok(snapshot);
        }
        let process = self.active_process(tui_id)?;
        process.send_input(&request.input)?;
        self.get(tui_id)
    }

    /// Resize an active TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is inactive or resize fails.
    pub fn resize(
        &self,
        tui_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed {
            let snapshot = BridgeClient::for_capability(BridgeCapability::AgentTui)?
                .agent_tui_resize(tui_id, request)?;
            self.save_and_broadcast("agent_tui_updated", &snapshot)?;
            return Ok(snapshot);
        }
        let process = self.active_process(tui_id)?;
        process.resize(request.size()?)?;
        self.get(tui_id)
    }

    /// Stop an active TUI.
    ///
    /// # Errors
    /// Returns [`CliError`] when the TUI is missing or process termination fails.
    #[expect(clippy::cognitive_complexity, reason = "bridge fallback adds one branch")]
    pub fn stop(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let snapshot = self.load_snapshot(tui_id)?;
        if self.state.sandboxed && snapshot.status == AgentTuiStatus::Running {
            match BridgeClient::for_capability(BridgeCapability::AgentTui)
                .and_then(|bridge| bridge.agent_tui_stop(tui_id))
            {
                Ok(stopped) => {
                    let _ = self.remove_active(tui_id)?;
                    self.save_and_broadcast("agent_tui_stopped", &stopped)?;
                    return Ok(stopped);
                }
                Err(error) => {
                    tracing::warn!(
                        %error,
                        tui_id,
                        "bridge unreachable during stop, falling back to local cleanup"
                    );
                }
            }
        }
        let process = self.remove_active(tui_id)?;
        if let Some(process) = process {
            process.kill()?;
            let _ = process.wait_timeout(Duration::from_millis(500))?;
            let profile =
                AgentTuiLaunchProfile::from_argv(&snapshot.runtime, snapshot.argv.clone())?;
            let snapshot_context = AgentTuiSnapshotContext {
                session_id: &snapshot.session_id,
                agent_id: &snapshot.agent_id,
                tui_id: &snapshot.tui_id,
                profile: &profile,
                project_dir: Path::new(&snapshot.project_dir),
                transcript_path: Path::new(&snapshot.transcript_path),
            };
            let mut stopped =
                snapshot_from_process(&snapshot_context, &process, AgentTuiStatus::Stopped)?;
            stopped.created_at = snapshot.created_at;
            self.save_and_broadcast("agent_tui_stopped", &stopped)?;
            return Ok(stopped);
        }

        let mut stopped = snapshot;
        stopped.status = AgentTuiStatus::Stopped;
        stopped.updated_at = utc_now();
        self.save_and_broadcast("agent_tui_stopped", &stopped)?;
        Ok(stopped)
    }

    fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        self.state
            .db
            .get()
            .cloned()
            .ok_or_else(|| CliErrorKind::workflow_io("daemon database is not ready").into())
    }

    fn active(&self) -> Result<MutexGuard<'_, BTreeMap<String, ActiveAgentTui>>, CliError> {
        lock(&self.state.active, "agent TUI active process map")
    }

    fn active_process(&self, tui_id: &str) -> Result<Arc<AgentTuiProcess>, CliError> {
        self.active()?
            .get(tui_id)
            .and_then(|active| active.process.clone())
            .ok_or_else(|| {
                CliErrorKind::session_not_active(format!("agent TUI '{tui_id}' is not active"))
                    .into()
            })
    }

    fn remove_active(&self, tui_id: &str) -> Result<Option<Arc<AgentTuiProcess>>, CliError> {
        let removed = self.active()?.remove(tui_id);
        if let Some(active) = &removed {
            active.stop();
        }
        Ok(removed.and_then(|active| active.process))
    }

    fn load_snapshot(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let db = self.db()?;
        lock_db(&db)?.agent_tui(tui_id)?.ok_or_else(|| {
            CliErrorKind::session_not_active(format!("agent TUI '{tui_id}' not found")).into()
        })
    }

    fn refresh_live_snapshot(
        &self,
        snapshot: AgentTuiSnapshot,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if self.state.sandboxed && snapshot.status == AgentTuiStatus::Running {
            return BridgeClient::for_capability(BridgeCapability::AgentTui)?
                .agent_tui_get(&snapshot.tui_id);
        }
        self.refresh_local_snapshot(snapshot)
    }

    fn refresh_local_snapshot(
        &self,
        mut snapshot: AgentTuiSnapshot,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let Some(process) = self
            .active()?
            .get(&snapshot.tui_id)
            .and_then(|active| active.process.clone())
        else {
            return Ok(snapshot);
        };

        if let Some(status) = process.try_wait()? {
            snapshot.status = AgentTuiStatus::Exited;
            snapshot.exit_code = Some(status.exit_code());
            snapshot.signal = status.signal().map(ToString::to_string);
            let _ = self.remove_active(&snapshot.tui_id)?;
        }

        snapshot.screen = process.screen()?;
        snapshot.size = snapshot.screen.size();
        snapshot.updated_at = utc_now();
        write_transcript(Path::new(&snapshot.transcript_path), &process.transcript()?)?;
        Ok(snapshot)
    }

    fn persist_refreshed_snapshot(
        &self,
        previous: &AgentTuiSnapshot,
        refreshed: &AgentTuiSnapshot,
    ) -> Result<(), CliError> {
        if !Self::snapshot_changed(previous, refreshed) {
            return Ok(());
        }
        self.save_and_broadcast("agent_tui_updated", refreshed)
    }

    fn snapshot_changed(previous: &AgentTuiSnapshot, refreshed: &AgentTuiSnapshot) -> bool {
        previous.status != refreshed.status
            || previous.size != refreshed.size
            || previous.screen != refreshed.screen
            || previous.exit_code != refreshed.exit_code
            || previous.signal != refreshed.signal
            || previous.error != refreshed.error
    }

    fn spawn_live_refresh(&self, tui_id: String, stop_flag: Arc<AtomicBool>) {
        let manager = self.clone();
        let _ = thread::spawn(move || {
            manager.run_live_refresh_loop(&tui_id, &stop_flag);
        });
    }

    fn run_live_refresh_loop(&self, tui_id: &str, stop_flag: &AtomicBool) {
        while Self::wait_for_live_refresh_tick(stop_flag) && self.handle_live_refresh_step(tui_id) {
        }

        let _ = self.remove_active(tui_id);
    }

    fn wait_for_live_refresh_tick(stop_flag: &AtomicBool) -> bool {
        if stop_flag.load(Ordering::Relaxed) {
            return false;
        }
        thread::sleep(LIVE_REFRESH_INTERVAL);
        !stop_flag.load(Ordering::Relaxed)
    }

    fn handle_live_refresh_step(&self, tui_id: &str) -> bool {
        self.live_refresh_step(tui_id).unwrap_or_else(|error| {
            Self::warn_live_refresh_failure(tui_id, &error);
            false
        })
    }

    fn live_refresh_step(&self, tui_id: &str) -> Result<bool, CliError> {
        let previous = self.load_snapshot(tui_id)?;
        if previous.status != AgentTuiStatus::Running {
            return Ok(false);
        }

        let refreshed = self.refresh_live_snapshot(previous.clone())?;
        self.persist_refreshed_snapshot(&previous, &refreshed)?;
        Ok(refreshed.status == AgentTuiStatus::Running)
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion in a leaf logging helper"
    )]
    fn warn_live_refresh_failure(tui_id: &str, error: &CliError) {
        tracing::warn!(tui_id = %tui_id, %error, "agent TUI live refresh failed");
    }

    fn save_and_broadcast(
        &self,
        event_name: &str,
        snapshot: &AgentTuiSnapshot,
    ) -> Result<(), CliError> {
        let db = self.db()?;
        lock_db(&db)?.save_agent_tui(snapshot)?;
        let payload = serde_json::to_value(snapshot).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("serialize agent TUI event: {error}"))
        })?;
        let event = StreamEvent {
            event: event_name.to_string(),
            recorded_at: utc_now(),
            session_id: Some(snapshot.session_id.clone()),
            payload,
        };
        let _ = self.state.sender.send(event);
        Ok(())
    }
}

pub(super) struct AgentTuiSnapshotContext<'a> {
    pub(super) session_id: &'a str,
    pub(super) agent_id: &'a str,
    pub(super) tui_id: &'a str,
    pub(super) profile: &'a AgentTuiLaunchProfile,
    pub(super) project_dir: &'a Path,
    pub(super) transcript_path: &'a Path,
}

pub(super) fn snapshot_from_process(
    context: &AgentTuiSnapshotContext<'_>,
    process: &AgentTuiProcess,
    status: AgentTuiStatus,
) -> Result<AgentTuiSnapshot, CliError> {
    let screen = process.screen()?;
    write_transcript(context.transcript_path, &process.transcript()?)?;
    let now = utc_now();
    Ok(AgentTuiSnapshot {
        tui_id: context.tui_id.to_string(),
        session_id: context.session_id.to_string(),
        agent_id: context.agent_id.to_string(),
        runtime: context.profile.runtime.clone(),
        status,
        argv: context.profile.argv.clone(),
        project_dir: context.project_dir.display().to_string(),
        size: screen.size(),
        screen,
        transcript_path: context.transcript_path.display().to_string(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Live process handle for an agent TUI running inside a PTY.
pub struct AgentTuiProcess {
    master: Shared<Box<dyn MasterPty + Send>>,
    child: Shared<Box<dyn Child + Send + Sync>>,
    writer: Shared<Box<dyn Write + Send>>,
    transcript: Shared<Vec<u8>>,
    screen: Shared<TerminalScreenParser>,
    reader_thread: Option<JoinHandle<()>>,
}

impl AgentTuiProcess {
    /// Spawn a child process into a PTY and start the output reader thread.
    ///
    /// # Errors
    /// Returns a workflow I/O error on PTY allocation, command spawn, or stream setup failure.
    pub fn spawn(spec: &AgentTuiSpawnSpec) -> Result<Self, CliError> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(spec.size.into())
            .map_err(|error| CliErrorKind::workflow_io(format!("open agent TUI PTY: {error}")))?;
        let cmd = command_builder(spec);
        let child = pair.slave.spawn_command(cmd).map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn agent TUI process: {error}"))
        })?;
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().map_err(|error| {
            CliErrorKind::workflow_io(format!("clone agent TUI PTY reader: {error}"))
        })?;
        let writer = pair.master.take_writer().map_err(|error| {
            CliErrorKind::workflow_io(format!("take agent TUI PTY writer: {error}"))
        })?;

        let transcript = Arc::new(Mutex::new(Vec::new()));
        let screen = Arc::new(Mutex::new(TerminalScreenParser::new(spec.size)));
        let reader_thread =
            spawn_reader_thread(reader, Arc::clone(&transcript), Arc::clone(&screen));

        Ok(Self {
            master: Arc::new(Mutex::new(pair.master)),
            child: Arc::new(Mutex::new(child)),
            writer: Arc::new(Mutex::new(writer)),
            transcript,
            screen,
            reader_thread: Some(reader_thread),
        })
    }

    /// Send structured keyboard input to the PTY.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when mapping or writing input fails.
    pub fn send_input(&self, input: &AgentTuiInput) -> Result<(), CliError> {
        self.write_bytes(&input.to_bytes()?)
    }

    /// Send raw bytes to the PTY.
    ///
    /// # Errors
    /// Returns a workflow I/O error when the PTY writer fails.
    pub fn write_bytes(&self, bytes: &[u8]) -> Result<(), CliError> {
        let mut writer = lock(&self.writer, "agent TUI writer")?;
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("write agent TUI input: {error}")).into()
            })
    }

    /// Resize the PTY and the parsed screen model.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when resize fails.
    pub fn resize(&self, size: AgentTuiSize) -> Result<(), CliError> {
        let size = size.validate()?;
        lock(&self.master, "agent TUI PTY master")?
            .resize(size.into())
            .map_err(|error| CliErrorKind::workflow_io(format!("resize agent TUI PTY: {error}")))?;
        lock(&self.screen, "agent TUI screen parser")?.resize(size);
        Ok(())
    }

    /// Return the latest parsed terminal screen.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn screen(&self) -> Result<TerminalScreenSnapshot, CliError> {
        Ok(lock(&self.screen, "agent TUI screen parser")?.snapshot())
    }

    /// Return a copy of the raw terminal transcript captured so far.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn transcript(&self) -> Result<Vec<u8>, CliError> {
        Ok(lock(&self.transcript, "agent TUI transcript")?.clone())
    }

    /// Poll the child process for exit status without blocking.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process polling fails.
    pub fn try_wait(&self) -> Result<Option<ExitStatus>, CliError> {
        lock(&self.child, "agent TUI child")?
            .try_wait()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("poll agent TUI process: {error}")).into()
            })
    }

    /// Wait until the child exits or the timeout elapses.
    ///
    /// # Errors
    /// Returns a workflow I/O error when polling fails.
    pub fn wait_timeout(&self, timeout: Duration) -> Result<Option<ExitStatus>, CliError> {
        let started = Instant::now();
        loop {
            if let Some(status) = self.try_wait()? {
                return Ok(Some(status));
            }
            if started.elapsed() >= timeout {
                return Ok(None);
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// Terminate the child process.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process termination fails.
    pub fn kill(&self) -> Result<(), CliError> {
        lock(&self.child, "agent TUI child")?
            .kill()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("kill agent TUI process: {error}")).into()
            })
    }
}

impl Drop for AgentTuiProcess {
    fn drop(&mut self) {
        if self
            .wait_timeout(Duration::from_millis(10))
            .ok()
            .flatten()
            .is_none()
            && let Ok(mut child) = self.child.lock()
        {
            let _ = child.kill();
        }
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }
}

fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

fn agent_tui_capabilities(existing: &[String], marker_capability: &str) -> Vec<String> {
    let mut capabilities = existing.to_vec();
    for capability in ["agent-tui", marker_capability] {
        if !capabilities.iter().any(|current| current == capability) {
            capabilities.push(capability.to_string());
        }
    }
    capabilities
}

struct ResolvedTuiProject {
    project_dir: PathBuf,
    context_root: PathBuf,
}

fn resolve_tui_project(
    db: &DaemonDb,
    session_id: &str,
    project_dir: Option<&str>,
) -> Result<ResolvedTuiProject, CliError> {
    if let Some(project_dir) = project_dir.filter(|value| !value.trim().is_empty()) {
        let project_dir = PathBuf::from(project_dir);
        return Ok(ResolvedTuiProject {
            context_root: project_context_dir(&project_dir),
            project_dir,
        });
    }

    let resolved = db.resolve_session(session_id)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("session '{session_id}' not found"))
    })?;
    let context_root = resolved.project.context_root;
    let project_dir = resolved
        .project
        .project_dir
        .or(resolved.project.repository_root)
        .unwrap_or_else(|| context_root.clone());
    Ok(ResolvedTuiProject {
        project_dir,
        context_root,
    })
}

fn agent_id_for_tui(state: &SessionState, marker_capability: &str) -> Result<String, CliError> {
    state
        .agents
        .values()
        .find(|agent| {
            agent
                .capabilities
                .iter()
                .any(|capability| capability == marker_capability)
        })
        .map(|agent| agent.agent_id.clone())
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "joined agent missing TUI marker capability '{marker_capability}'"
            ))
            .into()
        })
}

pub(super) fn spawn_agent_tui_process(
    session_id: &str,
    agent_id: &str,
    tui_id: &str,
    profile: AgentTuiLaunchProfile,
    project_dir: &Path,
    size: AgentTuiSize,
) -> Result<AgentTuiProcess, CliError> {
    let mut env = BTreeMap::new();
    env.insert("HARNESS_SESSION_ID".to_string(), session_id.to_string());
    env.insert("HARNESS_AGENT_ID".to_string(), agent_id.to_string());
    env.insert("HARNESS_AGENT_TUI_ID".to_string(), tui_id.to_string());
    let spec = AgentTuiSpawnSpec::new(profile, project_dir.to_path_buf(), env, size)?;
    PortablePtyAgentTuiBackend.spawn(spec)
}

pub(super) fn send_initial_prompt(process: &AgentTuiProcess, prompt: &str) -> Result<(), CliError> {
    process.send_input(&AgentTuiInput::Text {
        text: prompt.to_string(),
    })?;
    process.send_input(&AgentTuiInput::Key {
        key: AgentTuiKey::Enter,
    })
}

fn transcript_path(context_root: &Path, runtime: &str, tui_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("tui")
        .join(runtime)
        .join(tui_id)
        .join("output.raw")
}

fn write_transcript(path: &Path, transcript: &[u8]) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!("create agent TUI transcript dir: {error}"))
        })?;
    }
    fs_err::write(path, transcript).map_err(|error| {
        CliErrorKind::workflow_io(format!("write agent TUI transcript: {error}")).into()
    })
}

fn failed_snapshot(
    context: &AgentTuiSnapshotContext<'_>,
    size: AgentTuiSize,
    error: String,
) -> AgentTuiSnapshot {
    let screen = TerminalScreenParser::new(size).snapshot();
    let now = utc_now();
    AgentTuiSnapshot {
        tui_id: context.tui_id.to_string(),
        session_id: context.session_id.to_string(),
        agent_id: context.agent_id.to_string(),
        runtime: context.profile.runtime.clone(),
        status: AgentTuiStatus::Failed,
        argv: context.profile.argv.clone(),
        project_dir: context.project_dir.display().to_string(),
        size,
        screen,
        transcript_path: context.transcript_path.display().to_string(),
        exit_code: None,
        signal: None,
        error: Some(error),
        created_at: now.clone(),
        updated_at: now,
    }
}

fn command_builder(spec: &AgentTuiSpawnSpec) -> CommandBuilder {
    let argv = resolved_command_argv(&spec.profile);
    let mut cmd = CommandBuilder::from_argv(argv);
    cmd.cwd(spec.project_dir.as_os_str());
    cmd.env("TERM", "xterm-256color");
    if let Some(path) = agent_tui_spawn_path(&spec.profile.runtime) {
        cmd.env("PATH", path);
    }
    for (key, value) in &spec.env {
        cmd.env(key, value);
    }
    cmd
}

fn resolved_command_argv(profile: &AgentTuiLaunchProfile) -> Vec<OsString> {
    let mut argv = profile.argv.iter().map(OsString::from).collect::<Vec<_>>();
    let Some(program) = profile.argv.first() else {
        return argv;
    };
    if let Some(resolved) = resolve_agent_tui_program(&profile.runtime, program) {
        argv[0] = resolved.into_os_string();
    }
    argv
}

fn resolve_agent_tui_program(runtime: &str, program: &str) -> Option<PathBuf> {
    let path = Path::new(program);
    if path.is_absolute() || program.contains('/') {
        return is_executable(path).then(|| path.to_path_buf());
    }

    agent_tui_search_dirs(runtime)
        .into_iter()
        .find_map(|directory| {
            let candidate = directory.join(program);
            is_executable(&candidate).then_some(candidate)
        })
}

fn agent_tui_spawn_path(runtime: &str) -> Option<OsString> {
    let dirs = agent_tui_search_dirs(runtime);
    (!dirs.is_empty()).then(|| join_paths(dirs).expect("agent TUI PATH entries serialize"))
}

fn agent_tui_search_dirs(runtime: &str) -> Vec<PathBuf> {
    let home = dirs_home();
    let mut dirs = vec![home.join(".local").join("bin"), home.join("bin")];
    match runtime {
        "vibe" => {
            dirs.push(
                home.join(".local")
                    .join("share")
                    .join("uv")
                    .join("tools")
                    .join("mistral-vibe")
                    .join("bin"),
            );
        }
        "opencode" => dirs.push(home.join(".opencode").join("bin")),
        _ => {}
    }
    if let Some(path_env) = var_os("PATH") {
        for directory in split_paths(&path_env) {
            push_unique_path(&mut dirs, directory);
        }
    }
    dirs
}

fn push_unique_path(dirs: &mut Vec<PathBuf>, candidate: PathBuf) {
    if candidate.as_os_str().is_empty() || dirs.iter().any(|existing| existing == &candidate) {
        return;
    }
    dirs.push(candidate);
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

fn spawn_reader_thread(
    mut reader: Box<dyn Read + Send>,
    transcript: Shared<Vec<u8>>,
    screen: Shared<TerminalScreenParser>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    let bytes = &buffer[..read];
                    if let Ok(mut transcript) = transcript.lock() {
                        transcript.extend_from_slice(bytes);
                    }
                    if let Ok(mut screen) = screen.lock() {
                        screen.process(bytes);
                    }
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
    })
}

fn lock<'a, T>(mutex: &'a Mutex<T>, name: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("{name} lock poisoned: {error}")).into())
}

fn bracketed_paste_bytes(text: &str) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(text.len() + 12);
    bytes.extend_from_slice(b"\x1b[200~");
    bytes.extend_from_slice(text.as_bytes());
    bytes.extend_from_slice(b"\x1b[201~");
    bytes
}

fn control_key_bytes(key: char) -> Result<Vec<u8>, CliError> {
    let normalized = key.to_ascii_uppercase();
    if !normalized.is_ascii_alphabetic() {
        return Err(
            CliErrorKind::workflow_parse(format!("unsupported control key '{key}'")).into(),
        );
    }
    let byte = u8::try_from(normalized).map_err(|error| {
        CliErrorKind::workflow_parse(format!("invalid control key '{key}': {error}"))
    })?;
    Ok(vec![byte - b'A' + 1])
}

fn decode_raw_bytes(data: &str) -> Result<Vec<u8>, CliError> {
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    STANDARD.decode(data).map_err(|error| {
        CliErrorKind::workflow_parse(format!("invalid raw bytes base64: {error}")).into()
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::Duration;

    use tokio::sync::broadcast;

    use crate::daemon::db::DaemonDb;
    use crate::session::service as session_service;
    use crate::session::types::SessionRole;
    use crate::workspace::utc_now;

    use super::{
        AgentTuiBackend, AgentTuiInput, AgentTuiInputRequest, AgentTuiKey, AgentTuiLaunchProfile,
        AgentTuiManagerHandle, AgentTuiResizeRequest, AgentTuiSize, AgentTuiSnapshot,
        AgentTuiSpawnSpec, AgentTuiStartRequest, AgentTuiStatus, DEFAULT_WAIT_TIMEOUT,
        PortablePtyAgentTuiBackend, TerminalScreenParser, TerminalScreenSnapshot,
    };

    #[test]
    fn launch_profiles_cover_all_supported_runtimes() {
        let cases = [
            ("codex", "codex"),
            ("claude", "claude"),
            ("gemini", "gemini"),
            ("opencode", "opencode"),
            ("copilot", "copilot"),
            ("vibe", "vibe"),
        ];

        for (runtime, program) in cases {
            let profile = AgentTuiLaunchProfile::for_runtime(runtime).expect("profile");
            assert_eq!(profile.runtime, runtime);
            assert_eq!(profile.argv, vec![program.to_string()]);
        }
    }

    #[test]
    fn launch_profile_rejects_unknown_runtime() {
        let error = AgentTuiLaunchProfile::for_runtime("unknown").expect_err("runtime should fail");

        assert!(
            error
                .to_string()
                .contains("unsupported agent TUI runtime 'unknown'")
        );
    }

    #[test]
    fn launch_profile_override_rejects_empty_argv() {
        let error =
            AgentTuiLaunchProfile::from_argv("codex", Vec::new()).expect_err("argv should fail");

        assert!(error.to_string().contains("agent TUI argv cannot be empty"));
    }

    #[test]
    fn launch_profile_override_rejects_empty_program() {
        let error = AgentTuiLaunchProfile::from_argv("codex", vec![" ".to_string()])
            .expect_err("program should fail");

        assert!(
            error
                .to_string()
                .contains("agent TUI argv[0] cannot be empty")
        );
    }

    #[test]
    fn structured_input_maps_to_terminal_bytes() {
        assert_eq!(
            AgentTuiInput::Text {
                text: "hello".into()
            }
            .to_bytes()
            .expect("text bytes"),
            b"hello"
        );
        assert_eq!(
            AgentTuiInput::Key {
                key: AgentTuiKey::Enter
            }
            .to_bytes()
            .expect("enter bytes"),
            b"\r"
        );
        assert_eq!(
            AgentTuiInput::Key {
                key: AgentTuiKey::ArrowUp
            }
            .to_bytes()
            .expect("arrow bytes"),
            b"\x1b[A"
        );
        assert_eq!(
            AgentTuiInput::Control { key: 'c' }
                .to_bytes()
                .expect("control bytes"),
            b"\x03"
        );
    }

    #[test]
    fn paste_uses_bracketed_paste_sequences() {
        let bytes = AgentTuiInput::Paste {
            text: "multi\nline".into(),
        }
        .to_bytes()
        .expect("paste bytes");

        assert_eq!(bytes, b"\x1b[200~multi\nline\x1b[201~");
    }

    #[test]
    fn raw_bytes_decode_from_base64() {
        let bytes = AgentTuiInput::RawBytesBase64 {
            data: "AAEC".into(),
        }
        .to_bytes()
        .expect("raw bytes");

        assert_eq!(bytes, vec![0, 1, 2]);
    }

    #[test]
    fn size_rejects_zero_dimensions() {
        let error = AgentTuiSize { rows: 0, cols: 120 }
            .validate()
            .expect_err("size should fail");

        assert!(
            error
                .to_string()
                .contains("agent TUI rows and cols must be greater than zero")
        );
    }

    #[test]
    fn terminal_parser_preserves_visible_text_and_resize() {
        let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 4, cols: 20 });
        parser.process(b"hello\x1b[2;1Hworld");
        let snapshot = parser.snapshot();
        assert_eq!(snapshot.rows, 4);
        assert_eq!(snapshot.cols, 20);
        assert!(snapshot.text.contains("hello"));
        assert!(snapshot.text.contains("world"));

        parser.resize(AgentTuiSize { rows: 10, cols: 40 });
        let resized = parser.snapshot();
        assert_eq!(resized.rows, 10);
        assert_eq!(resized.cols, 40);
    }

    #[test]
    fn terminal_parser_trims_leading_newlines() {
        let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 5, cols: 40 });
        // Position cursor at row 3, col 1 and print "hello"
        // Row 1: empty
        // Row 2: empty
        // Row 3: hello
        parser.process(b"\x1b[3;1Hhello");

        let snapshot = parser.snapshot();
        // vt100's screen.contents() will have leading newlines for the empty rows.
        // We want them gone.
        assert!(!snapshot.text.starts_with('\n'), "should not start with newline");
        assert!(snapshot.text.starts_with("hello"), "should start with hello");
    }

    #[test]
    fn terminal_parser_preserves_row_zero_content() {
        let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 5, cols: 40 });
        // Content starts at the very top
        parser.process(b"top-content");

        let snapshot = parser.snapshot();
        assert!(snapshot.text.starts_with("top-content"));
    }

    #[test]
    fn portable_pty_backend_round_trips_line_input() {
        let process = spawn_shell("cat");
        process
            .send_input(&AgentTuiInput::Text {
                text: "hello from pty".into(),
            })
            .expect("send text");
        process
            .send_input(&AgentTuiInput::Key {
                key: AgentTuiKey::Enter,
            })
            .expect("send enter");

        wait_until(DEFAULT_WAIT_TIMEOUT, || {
            String::from_utf8_lossy(&process.transcript().expect("transcript"))
                .contains("hello from pty")
        });
    }

    #[test]
    fn portable_pty_backend_preserves_raw_ansi_and_parses_screen_text() {
        let process = spawn_shell("printf '\\033[31mred\\033[0m\\n'");
        let status = process
            .wait_timeout(DEFAULT_WAIT_TIMEOUT)
            .expect("wait")
            .expect("status");
        assert!(status.success());

        let transcript = process.transcript().expect("transcript");
        assert!(
            transcript
                .windows(b"\x1b[31m".len())
                .any(|chunk| chunk == b"\x1b[31m")
        );
        assert!(process.screen().expect("screen").text.contains("red"));
    }

    #[test]
    fn portable_pty_backend_sends_control_c() {
        let process = spawn_shell("sleep 10");
        process
            .send_input(&AgentTuiInput::Control { key: 'c' })
            .expect("send ctrl-c");

        let status = process
            .wait_timeout(DEFAULT_WAIT_TIMEOUT)
            .expect("wait for interrupt");
        assert!(status.is_some(), "process should exit after ctrl-c");
    }

    #[test]
    fn portable_pty_backend_resizes_screen_model() {
        let process = spawn_shell("cat");
        process
            .resize(AgentTuiSize { rows: 9, cols: 33 })
            .expect("resize");

        let screen = process.screen().expect("screen");
        assert_eq!(screen.rows, 9);
        assert_eq!(screen.cols, 33);
    }

    #[test]
    fn portable_pty_backend_resolves_vibe_from_local_bin_when_missing_from_path() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join("home");
        let vibe = home.join(".local").join("bin").join("vibe");
        write_executable_script(&vibe, "#!/bin/sh\nprintf 'vibe-local-bin\\n'\n");

        temp_env::with_vars(
            [
                ("HOME", Some(home.to_str().expect("utf8 home"))),
                ("PATH", Some("/usr/bin:/bin")),
            ],
            || {
                let process = spawn_runtime("vibe");
                let status = process
                    .wait_timeout(DEFAULT_WAIT_TIMEOUT)
                    .expect("wait")
                    .expect("status");
                assert!(status.success());
                assert!(
                    process
                        .screen()
                        .expect("screen")
                        .text
                        .contains("vibe-local-bin")
                );
            },
        );
    }

    #[test]
    fn portable_pty_backend_resolves_vibe_from_uv_tool_dir_without_local_bin_symlink() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join("home");
        let vibe = home
            .join(".local")
            .join("share")
            .join("uv")
            .join("tools")
            .join("mistral-vibe")
            .join("bin")
            .join("vibe");
        write_executable_script(&vibe, "#!/bin/sh\nprintf 'vibe-uv-tool\\n'\n");

        temp_env::with_vars(
            [
                ("HOME", Some(home.to_str().expect("utf8 home"))),
                ("PATH", Some("/usr/bin:/bin")),
            ],
            || {
                let process = spawn_runtime("vibe");
                let status = process
                    .wait_timeout(DEFAULT_WAIT_TIMEOUT)
                    .expect("wait")
                    .expect("status");
                assert!(status.success());
                assert!(
                    process
                        .screen()
                        .expect("screen")
                        .text
                        .contains("vibe-uv-tool")
                );
            },
        );
    }

    #[test]
    fn manager_starts_registers_steers_and_stops_tui() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-manager".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-tui-manager".into(),
            checkout_name: "Directory".into(),
            context_root: context_root.clone(),
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "managed tui test",
            "managed tui",
            "sess-tui-manager",
            "claude",
            None,
            &utc_now(),
        );
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, mut receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-tui-manager",
                &AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    capabilities: vec!["test-harness".into()],
                    name: Some("PTY worker".into()),
                    prompt: None,
                    project_dir: None,
                    argv: vec!["sh".into(), "-c".into(), "cat".into()],
                    rows: 5,
                    cols: 40,
                },
            )
            .expect("start manager TUI");

        assert_eq!(snapshot.status, AgentTuiStatus::Running);
        assert_eq!(snapshot.runtime, "codex");
        assert_eq!(snapshot.argv, vec!["sh", "-c", "cat"]);
        assert!(PathBuf::from(&snapshot.transcript_path).exists());
        assert!(PathBuf::from(&snapshot.transcript_path).starts_with(&context_root));

        let started_event = receiver.try_recv().expect("started event");
        assert_eq!(started_event.event, "agent_tui_started");
        assert_eq!(
            started_event.session_id.as_deref(),
            Some("sess-tui-manager")
        );

        {
            let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
            let state = db_guard
                .load_session_state("sess-tui-manager")
                .expect("load state")
                .expect("state present");
            let joined = state.agents.get(&snapshot.agent_id).expect("joined agent");
            assert_eq!(joined.runtime, "codex");
            assert!(joined.capabilities.iter().any(|item| item == "agent-tui"));
            assert!(
                joined
                    .capabilities
                    .iter()
                    .any(|item| item == &format!("agent-tui:{}", snapshot.tui_id))
            );
        }

        manager
            .input(
                &snapshot.tui_id,
                &AgentTuiInputRequest {
                    input: AgentTuiInput::Text {
                        text: "hello from manager".into(),
                    },
                },
            )
            .expect("send text");
        manager
            .input(
                &snapshot.tui_id,
                &AgentTuiInputRequest {
                    input: AgentTuiInput::Key {
                        key: AgentTuiKey::Enter,
                    },
                },
            )
            .expect("send enter");

        wait_until(DEFAULT_WAIT_TIMEOUT, || {
            manager
                .get(&snapshot.tui_id)
                .expect("refresh snapshot")
                .screen
                .text
                .contains("hello from manager")
        });

        let resized = manager
            .resize(
                &snapshot.tui_id,
                &AgentTuiResizeRequest { rows: 9, cols: 33 },
            )
            .expect("resize");
        assert_eq!(resized.size, AgentTuiSize { rows: 9, cols: 33 });

        let stopped = manager.stop(&snapshot.tui_id).expect("stop");
        assert_eq!(stopped.status, AgentTuiStatus::Stopped);
        let transcript = fs_err::read(&stopped.transcript_path).expect("read transcript file");
        assert!(String::from_utf8_lossy(&transcript).contains("hello from manager"));
    }

    #[test]
    fn manager_publishes_terminal_output_without_manual_refresh() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-live-refresh".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-tui-live-refresh".into(),
            checkout_name: "Directory".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "live refresh tui test",
            "managed tui",
            "sess-tui-live-refresh",
            "claude",
            None,
            &utc_now(),
        );
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, mut receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-tui-live-refresh",
                &AgentTuiStartRequest {
                    runtime: "claude".into(),
                    role: SessionRole::Worker,
                    capabilities: vec![],
                    name: Some("Delayed output".into()),
                    prompt: None,
                    project_dir: None,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "sleep 0.2; printf 'agent-ready\\n'; sleep 0.2".into(),
                    ],
                    rows: 5,
                    cols: 40,
                },
            )
            .expect("start manager TUI");

        let started_event = receiver.try_recv().expect("started event");
        assert_eq!(started_event.event, "agent_tui_started");

        let mut updated_snapshot = None;
        wait_until(DEFAULT_WAIT_TIMEOUT, || {
            while let Ok(event) = receiver.try_recv() {
                if event.event != "agent_tui_updated" {
                    continue;
                }
                let event_snapshot: AgentTuiSnapshot =
                    serde_json::from_value(event.payload).expect("decode snapshot");
                if event_snapshot.tui_id == snapshot.tui_id
                    && event_snapshot.screen.text.contains("agent-ready")
                {
                    updated_snapshot = Some(event_snapshot);
                    return true;
                }
            }
            false
        });

        let updated_snapshot = updated_snapshot.expect("updated snapshot");
        assert_eq!(updated_snapshot.tui_id, snapshot.tui_id);
        assert!(updated_snapshot.screen.text.contains("agent-ready"));
    }

    #[test]
    fn manager_list_prioritizes_leader_tui_over_worker_refresh_order() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-ordering".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir),
            checkout_id: "checkout-tui-ordering".into(),
            checkout_name: "Directory".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let mut state = session_service::build_new_session(
            "ordering test",
            "ordering",
            "sess-tui-ordering",
            "claude",
            None,
            &utc_now(),
        );
        let worker_id = "codex-worker".to_string();
        state.agents.insert(
            worker_id.clone(),
            crate::session::types::AgentRegistration {
                agent_id: worker_id.clone(),
                name: "Worker".into(),
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec![],
                joined_at: "2026-04-12T09:00:00Z".into(),
                updated_at: "2026-04-12T09:00:00Z".into(),
                status: crate::session::types::AgentStatus::Active,
                agent_session_id: Some("codex-worker-session".into()),
                last_activity_at: Some("2026-04-12T09:00:00Z".into()),
                current_task_id: None,
                runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
            },
        );
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let leader_id = state.leader_id.expect("leader id");
        db.save_agent_tui(&sample_snapshot(
            "leader-tui",
            &state.session_id,
            &leader_id,
            "claude",
            "2026-04-12T09:00:00Z",
            "2026-04-12T09:01:00Z",
        ))
        .expect("save leader tui");
        db.save_agent_tui(&sample_snapshot(
            "worker-tui",
            &state.session_id,
            &worker_id,
            "codex",
            "2026-04-12T09:02:00Z",
            "2026-04-12T09:05:00Z",
        ))
        .expect("save worker tui");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, _) = broadcast::channel(4);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

        let listed = manager
            .list("sess-tui-ordering")
            .expect("list tuis")
            .tuis
            .into_iter()
            .map(|item| item.tui_id)
            .collect::<Vec<_>>();
        assert_eq!(listed, vec!["leader-tui", "worker-tui"]);
    }

    fn sample_snapshot(
        tui_id: &str,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        created_at: &str,
        updated_at: &str,
    ) -> AgentTuiSnapshot {
        AgentTuiSnapshot {
            tui_id: tui_id.to_string(),
            session_id: session_id.to_string(),
            agent_id: agent_id.to_string(),
            runtime: runtime.to_string(),
            status: AgentTuiStatus::Running,
            argv: vec![runtime.to_string()],
            project_dir: "/tmp/project".to_string(),
            size: AgentTuiSize { rows: 24, cols: 80 },
            screen: TerminalScreenSnapshot {
                rows: 24,
                cols: 80,
                cursor_row: 1,
                cursor_col: 1,
                text: "ready".to_string(),
            },
            transcript_path: "/tmp/transcript.log".to_string(),
            exit_code: None,
            signal: None,
            error: None,
            created_at: created_at.to_string(),
            updated_at: updated_at.to_string(),
        }
    }

    #[test]
    fn sandboxed_stop_without_bridge_falls_back_to_local_cleanup() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_dir = tmp.path().join("project");
        let daemon_home = tmp.path().join("daemon-home");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-stop-test".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-stop-test".into(),
            checkout_name: "Directory".into(),
            context_root: tmp.path().join("context-root"),
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let session_state = session_service::build_new_session(
            "stop test",
            "stop test",
            "sess-stop-test",
            "claude",
            None,
            &utc_now(),
        );
        db.sync_session(&project.project_id, &session_state)
            .expect("sync session");
        let now = utc_now();

        let snapshot = AgentTuiSnapshot {
            tui_id: "agent-tui-test-stop".into(),
            session_id: "sess-stop-test".into(),
            agent_id: "agent-stop-test".into(),
            runtime: "codex".into(),
            status: AgentTuiStatus::Running,
            argv: vec!["sh".into(), "-c".into(), "cat".into()],
            project_dir: tmp.path().display().to_string(),
            size: AgentTuiSize { rows: 24, cols: 80 },
            screen: TerminalScreenSnapshot {
                rows: 24,
                cols: 80,
                cursor_row: 0,
                cursor_col: 0,
                text: String::new(),
            },
            transcript_path: tmp.path().join("transcript.jsonl").display().to_string(),
            exit_code: None,
            signal: None,
            error: None,
            created_at: now.clone(),
            updated_at: now,
        };
        db.save_agent_tui(&snapshot).expect("seed snapshot");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, mut receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

        let active = super::ActiveAgentTui::new(None);
        manager
            .active()
            .expect("active map")
            .insert("agent-tui-test-stop".into(), active);

        let stopped = temp_env::with_vars(
            [(
                "HARNESS_DAEMON_DATA_HOME",
                Some(daemon_home.to_str().expect("utf8 daemon home")),
            )],
            || manager.stop("agent-tui-test-stop"),
        )
        .expect("stop should succeed without bridge");

        assert_eq!(stopped.status, AgentTuiStatus::Stopped);
        assert_eq!(stopped.tui_id, "agent-tui-test-stop");

        let event = receiver.try_recv().expect("stopped event");
        assert_eq!(event.event, "agent_tui_stopped");
    }

    #[test]
    fn sandboxed_start_without_bridge_does_not_join_agent() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        let daemon_home = tmp.path().join("daemon-home");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-manager".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-tui-manager".into(),
            checkout_name: "Directory".into(),
            context_root: context_root.clone(),
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "managed tui test",
            "managed tui",
            "sess-tui-manager",
            "claude",
            None,
            &utc_now(),
        );
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, _) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

        temp_env::with_vars(
            [(
                "HARNESS_DAEMON_DATA_HOME",
                Some(daemon_home.to_str().expect("utf8 daemon home")),
            )],
            || {
                let error = manager
                    .start(
                        "sess-tui-manager",
                        &AgentTuiStartRequest {
                            runtime: "copilot".into(),
                            role: SessionRole::Worker,
                            capabilities: vec![],
                            name: Some("Copilot TUI".into()),
                            prompt: Some("hello".into()),
                            project_dir: None,
                            argv: vec![],
                            rows: 24,
                            cols: 80,
                        },
                    )
                    .expect_err("start should fail without bridge");

                assert!(error.message().contains("agent-tui.host-bridge"));
            },
        );

        let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
        let state = db_guard
            .load_session_state("sess-tui-manager")
            .expect("load state")
            .expect("state present");
        assert!(state.agents.values().all(|agent| {
            agent
                .capabilities
                .iter()
                .all(|capability| capability != "agent-tui")
        }));
    }

    fn spawn_shell(script: &str) -> super::AgentTuiProcess {
        let profile = AgentTuiLaunchProfile::from_argv(
            "codex",
            vec!["sh".to_string(), "-c".to_string(), script.to_string()],
        )
        .expect("profile");
        let spec = AgentTuiSpawnSpec::new(
            profile,
            PathBuf::from("."),
            BTreeMap::new(),
            AgentTuiSize { rows: 5, cols: 40 },
        )
        .expect("spec");
        PortablePtyAgentTuiBackend
            .spawn(spec)
            .expect("spawn pty process")
    }

    fn spawn_runtime(runtime: &str) -> super::AgentTuiProcess {
        let profile = AgentTuiLaunchProfile::for_runtime(runtime).expect("profile");
        let spec = AgentTuiSpawnSpec::new(
            profile,
            PathBuf::from("."),
            BTreeMap::new(),
            AgentTuiSize { rows: 5, cols: 40 },
        )
        .expect("spec");
        PortablePtyAgentTuiBackend
            .spawn(spec)
            .expect("spawn runtime")
    }

    fn write_executable_script(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            fs_err::create_dir_all(parent).expect("create script dir");
        }
        fs_err::write(path, contents).expect("write script");
        let mut permissions = fs_err::metadata(path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs_err::set_permissions(path, permissions).expect("chmod script");
    }

    fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if condition() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(condition(), "condition should become true before timeout");
    }
}
