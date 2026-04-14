use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::process::id as process_id;
use std::slice;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use crate::agents::runtime as agents_runtime;
use crate::agents::runtime::signal::{
    AckResult, SignalAck, acknowledge_signal as write_signal_ack,
};
use crate::agents::service as agents_service;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::session::types::{
    AgentRegistration, SessionLogEntry, SessionRole, SessionState, SessionStatus,
    SessionTransition, TaskSource,
};
use crate::session::{
    observe as session_observe, service as session_service, storage as session_storage,
};
use crate::workspace::utc_now;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::runtime::Handle;
use tokio::sync::{broadcast, watch as tokio_watch};
use tokio::task::{AbortHandle, spawn_blocking};

use super::agent_tui::AgentTuiManagerHandle;
use super::bridge;
use super::codex_controller::CodexControllerHandle;
use super::codex_transport::{self, CodexTransportKind};
use super::http::{self, DaemonHttpState};
use super::index::{self, ResolvedSession};
use super::launchd::{self, LaunchAgentStatus};
use super::protocol::{
    AgentRemoveRequest, DaemonControlResponse, DaemonDiagnosticsReport, HealthResponse,
    LeaderTransferRequest, LogLevelResponse, ObserveSessionRequest, ProjectSummary,
    ReadyEventPayload, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionExtensionsPayload, SessionSummary, SessionUpdatedPayload, SessionsUpdatedPayload,
    SetLogLevelRequest, SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskDropRequest, TaskQueuePolicyRequest, TaskUpdateRequest, TimelineCursor,
    TimelineEntry, TimelineWindowRequest, TimelineWindowResponse,
};
use super::snapshot;
use super::state::{self, DaemonDiagnostics, DaemonManifest};
use super::timeline;
use super::watch;
use super::websocket::ReplayBuffer;

#[derive(Debug, Clone)]
struct DaemonObserveRuntime {
    sender: broadcast::Sender<StreamEvent>,
    poll_interval: Duration,
    running_sessions: Arc<Mutex<BTreeMap<String, ObserveLoopRegistration>>>,
    db: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ObserveLoopRequest {
    actor_id: Option<String>,
}

impl ObserveLoopRequest {
    fn new(actor_id: Option<&str>) -> Self {
        Self {
            actor_id: actor_id
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string),
        }
    }
}

#[derive(Debug)]
struct ObserveLoopRegistration {
    request: ObserveLoopRequest,
    generation: u64,
    abort_handle: AbortHandle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ObserveLoopState {
    Unavailable,
    Started,
    AlreadyRunning,
    Restarted,
}

static OBSERVE_RUNTIME: OnceLock<DaemonObserveRuntime> = OnceLock::new();
static SHUTDOWN_SIGNAL: OnceLock<tokio_watch::Sender<bool>> = OnceLock::new();
static SESSION_LIVENESS_REFRESH_CACHE: OnceLock<Mutex<BTreeMap<String, Instant>>> = OnceLock::new();

const SESSION_LIVENESS_REFRESH_TTL: Duration = Duration::from_secs(5);
const ACTIVE_SIGNAL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
const ACTIVE_SIGNAL_ACK_POLL_INTERVAL: Duration = Duration::from_millis(50);

struct ActiveSignalDelivery<'a> {
    session_id: &'a str,
    agent_id: &'a str,
    signal: &'a agents_runtime::signal::Signal,
    runtime: &'a dyn agents_runtime::AgentRuntime,
    project_dir: &'a Path,
    signal_session_id: &'a str,
    db: Option<&'a super::db::DaemonDb>,
}

struct ManagedTuiWake<'a> {
    tui_id: &'a str,
    manager: &'a AgentTuiManagerHandle,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatusReport {
    pub manifest: Option<DaemonManifest>,
    pub launch_agent: LaunchAgentStatus,
    pub project_count: usize,
    pub worktree_count: usize,
    pub session_count: usize,
    pub diagnostics: DaemonDiagnostics,
}

#[derive(Debug, Clone)]
pub struct DaemonServeConfig {
    pub host: String,
    pub port: u16,
    pub poll_interval: Duration,
    pub observe_interval: Duration,
    /// Whether the daemon is running inside the macOS App Sandbox.
    ///
    /// When true, subprocess-based platform integration (e.g. `launchctl`
    /// invocations, respawning the daemon binary directly) is disabled and
    /// surfaces a structured error instead of attempting the operation.
    pub sandboxed: bool,
    /// How the daemon should reach its Codex app-server. Sandboxed daemons
    /// default to WebSocket because they cannot spawn subprocesses; the
    /// unsandboxed default is stdio. See [`codex_transport_from_env`].
    pub codex_transport: CodexTransportKind,
}

impl Default for DaemonServeConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            poll_interval: Duration::from_secs(2),
            observe_interval: Duration::from_secs(5),
            sandboxed: false,
            codex_transport: CodexTransportKind::Stdio,
        }
    }
}

/// Resolve the Codex transport kind for a given sandbox mode, consulting
/// `HARNESS_CODEX_WS_URL`. Delegates to [`codex_transport::codex_transport_from_env`].
#[must_use]
pub fn codex_transport_from_env(sandboxed: bool) -> CodexTransportKind {
    codex_transport::codex_transport_from_env(sandboxed)
}

/// Returns true when `HARNESS_SANDBOXED` is set to a truthy value (`1`, `true`, `yes`, `on`).
#[must_use]
pub fn sandboxed_from_env() -> bool {
    env::var("HARNESS_SANDBOXED").ok().is_some_and(|value| {
        matches!(
            value.trim(),
            "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON"
        )
    })
}

/// Returns true when the current working directory is under
/// `Library/Group Containers/`, which is a strong signal that the process
/// launched inside the macOS App Sandbox.
#[must_use]
pub fn cwd_looks_sandboxed() -> bool {
    env::current_dir()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok())
        .is_some_and(|path| path.contains("Library/Group Containers/"))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_sandbox_startup(sandboxed: bool) {
    tracing::info!(sandboxed, "daemon starting");
    if !sandboxed && cwd_looks_sandboxed() {
        tracing::warn!(
            "daemon cwd is under Library/Group Containers/ but HARNESS_SANDBOXED is unset; \
             subprocess features may fail under the macOS App Sandbox"
        );
    }
}

/// Run the local daemon HTTP server until the process exits.
///
/// # Errors
/// Returns `CliError` on bind or filesystem failures.
pub async fn serve(config: DaemonServeConfig) -> Result<(), CliError> {
    validate_serve_config(&config)?;
    log_sandbox_startup(config.sandboxed);

    state::ensure_daemon_dirs()?;
    super::voice::cleanup_abandoned_sessions()?;
    let daemon_lock = state::acquire_singleton_lock()?;
    let token = state::ensure_auth_token()?;

    let listener = TcpListener::bind((config.host.as_str(), config.port))
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("bind daemon listener: {error}")))?;
    let local_addr = listener.local_addr().map_err(|error| {
        CliErrorKind::workflow_io(format!("read daemon listener addr: {error}"))
    })?;
    let endpoint = format!("http://{local_addr}");

    let manifest = DaemonManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: process_id(),
        endpoint: endpoint.clone(),
        started_at: utc_now(),
        token_path: state::auth_token_path().display().to_string(),
        sandboxed: config.sandboxed,
        host_bridge: bridge::host_bridge_manifest()?,
        // write_manifest bumps revision/updated_at for us - these are
        // just placeholders so the struct literal is well-typed.
        revision: 0,
        updated_at: String::new(),
    };
    state::write_manifest(&manifest)?;
    state::append_event("info", &format!("daemon listening on {endpoint}"))?;

    let (sender, _) = broadcast::channel(64);
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let db: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>> = Arc::new(OnceLock::new());
    let _ = OBSERVE_RUNTIME.set(DaemonObserveRuntime {
        sender: sender.clone(),
        poll_interval: config.observe_interval,
        running_sessions: Arc::default(),
        db: db.clone(),
    });
    let _ = SHUTDOWN_SIGNAL.set(shutdown_tx.clone());
    let replay_buffer = Arc::new(Mutex::new(ReplayBuffer::new(512)));
    let daemon_epoch = manifest.started_at.clone();

    initialize_db_and_spawn_background_tasks(&db, sender.clone(), config.poll_interval);
    let codex_controller = CodexControllerHandle::new(sender.clone(), db.clone(), config.sandboxed);
    let agent_tui_manager =
        super::agent_tui::AgentTuiManagerHandle::new(sender.clone(), db.clone(), config.sandboxed);
    let _bridge_watcher = bridge::spawn_manifest_watcher();

    let app_state = DaemonHttpState {
        token,
        sender,
        manifest,
        daemon_epoch,
        replay_buffer,
        db,
        codex_controller,
        agent_tui_manager,
    };

    let serve_result = http::serve(listener, app_state, shutdown_rx).await;
    let cleanup_result = state::clear_manifest_for_pid(process_id());
    let stop_event_result = if serve_result.is_ok() {
        state::append_event("info", "daemon stopped")
    } else {
        Ok(())
    };
    drop(daemon_lock);

    match (serve_result, cleanup_result, stop_event_result) {
        (Err(error), _, _) | (Ok(()), Err(error), _) | (Ok(()), Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(()), Ok(())) => Ok(()),
    }
}

fn validate_serve_config(config: &DaemonServeConfig) -> Result<(), CliError> {
    if !super::is_loopback_host(&config.host) {
        return Err(CliErrorKind::workflow_parse(format!(
            "daemon host must be loopback-only: {}",
            config.host
        ))
        .into());
    }
    if let CodexTransportKind::WebSocket { endpoint } = &config.codex_transport
        && config.sandboxed
        && !super::is_local_websocket_endpoint(endpoint)
    {
        return Err(CliErrorKind::workflow_parse(format!(
            "sandboxed Codex websocket endpoint must be loopback-only: {endpoint}"
        ))
        .into());
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn open_and_publish_db(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
) -> Option<Arc<Mutex<super::db::DaemonDb>>> {
    let db_path = state::daemon_root().join("harness.db");
    let db = open_daemon_db(&db_path)?;
    let db = Arc::new(Mutex::new(db));
    let _ = db_slot.set(Arc::clone(&db));
    tracing::info!("database ready");
    Some(db)
}

fn initialize_db_and_spawn_background_tasks(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    sender: broadcast::Sender<super::protocol::StreamEvent>,
    poll_interval: Duration,
) {
    let Some(db) = open_and_publish_db(db_slot) else {
        return;
    };

    let db_option = Some(Arc::clone(&db));
    let _watch = watch::spawn_watch_loop(sender, poll_interval, db_option.clone());
    spawn_background_reconciliation(db_option.clone());
    spawn_background_diagnostics(db_option);
}

fn spawn_background_reconciliation(db: Option<Arc<Mutex<super::db::DaemonDb>>>) {
    let Some(db) = db else {
        return;
    };
    tokio::spawn(async move {
        let _ = spawn_blocking(move || run_background_reconciliation(&db)).await;
    });
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn run_background_reconciliation(db: &Arc<Mutex<super::db::DaemonDb>>) {
    let (projects, sessions) = match discover_background_reconciliation_inputs() {
        Ok(inputs) => inputs,
        Err(error) => {
            tracing::warn!(%error, "background file reconciliation failed");
            let _ = state::append_event(
                "warn",
                &format!("background file reconciliation failed: {error}"),
            );
            return;
        }
    };

    let mut result = super::db::ReconcileResult::default();
    let sessions_to_prepare = match sync_background_projects_and_collect_candidates(
        db,
        &projects,
        &sessions,
        &mut result,
    ) {
        Ok(sessions) => sessions,
        Err(error) => {
            tracing::warn!(%error, "background file reconciliation failed");
            let _ = state::append_event(
                "warn",
                &format!("background file reconciliation failed: {error}"),
            );
            return;
        }
    };

    for resolved in &sessions_to_prepare {
        match apply_background_session_import(db, resolved) {
            BackgroundSessionImportOutcome::Imported => result.sessions_imported += 1,
            BackgroundSessionImportOutcome::Skipped => result.sessions_skipped += 1,
            BackgroundSessionImportOutcome::Failed => {}
        }
    }
    let message = format!(
        "background reconciliation: {} projects, {} sessions imported, {} skipped",
        result.projects, result.sessions_imported, result.sessions_skipped
    );
    tracing::info!("{message}");
    let _ = state::append_event("info", &message);
}

fn discover_background_reconciliation_inputs() -> Result<
    (
        Vec<super::index::DiscoveredProject>,
        Vec<super::index::ResolvedSession>,
    ),
    CliError,
> {
    let projects = index::discover_projects()?;
    let mut sessions = index::discover_sessions_for(&projects, true)?;
    sessions.sort_by(|left, right| {
        let left_active = left.state.status == SessionStatus::Active;
        let right_active = right.state.status == SessionStatus::Active;
        right_active
            .cmp(&left_active)
            .then(right.state.updated_at.cmp(&left.state.updated_at))
            .then(left.state.session_id.cmp(&right.state.session_id))
    });
    Ok((projects, sessions))
}

fn sync_background_projects_and_collect_candidates(
    db: &Arc<Mutex<super::db::DaemonDb>>,
    projects: &[super::index::DiscoveredProject],
    sessions: &[super::index::ResolvedSession],
    result: &mut super::db::ReconcileResult,
) -> Result<Vec<super::index::ResolvedSession>, CliError> {
    let Ok(db_guard) = db.lock() else {
        return Ok(Vec::new());
    };
    sync_background_projects(&db_guard, projects, result)?;
    Ok(collect_background_session_candidates(
        &db_guard, sessions, result,
    ))
}

enum BackgroundSessionImportOutcome {
    Failed,
    Imported,
    Skipped,
}

enum BackgroundSessionCandidate {
    Failed,
    Prepare,
    Skip,
}

fn apply_background_session_import(
    db: &Arc<Mutex<super::db::DaemonDb>>,
    resolved: &super::index::ResolvedSession,
) -> BackgroundSessionImportOutcome {
    let Some(prepared) = prepare_background_session_import(resolved) else {
        return BackgroundSessionImportOutcome::Failed;
    };
    let Ok(db_guard) = db.lock() else {
        return BackgroundSessionImportOutcome::Failed;
    };
    apply_prepared_background_session_import(&db_guard, &prepared)
}

fn sync_background_projects(
    db: &super::db::DaemonDb,
    projects: &[super::index::DiscoveredProject],
    result: &mut super::db::ReconcileResult,
) -> Result<(), CliError> {
    for project in projects {
        db.sync_project(project).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "sync project {}: {error}",
                project.project_id
            )))
        })?;
        result.projects += 1;
    }
    Ok(())
}

fn collect_background_session_candidates(
    db: &super::db::DaemonDb,
    sessions: &[super::index::ResolvedSession],
    result: &mut super::db::ReconcileResult,
) -> Vec<super::index::ResolvedSession> {
    let mut sessions_to_prepare = Vec::new();
    for resolved in sessions {
        match background_session_candidate(db, resolved) {
            BackgroundSessionCandidate::Prepare => sessions_to_prepare.push(resolved.clone()),
            BackgroundSessionCandidate::Skip | BackgroundSessionCandidate::Failed => {
                result.sessions_skipped += 1;
            }
        }
    }
    sessions_to_prepare
}

fn prepare_background_session_import(
    resolved: &super::index::ResolvedSession,
) -> Option<super::db::PreparedSessionResync> {
    super::db::DaemonDb::prepare_session_import_from_resolved(resolved)
        .inspect_err(|error| log_background_session_prepare_error(error, resolved))
        .ok()
}

fn apply_prepared_background_session_import(
    db: &super::db::DaemonDb,
    prepared: &super::db::PreparedSessionResync,
) -> BackgroundSessionImportOutcome {
    let Some(import_required) = prepared_session_import_required(db, prepared) else {
        return BackgroundSessionImportOutcome::Failed;
    };
    if !import_required {
        return BackgroundSessionImportOutcome::Skipped;
    }
    import_prepared_background_session(db, prepared)
}

fn session_import_required(
    db: &super::db::DaemonDb,
    resolved: &super::index::ResolvedSession,
) -> Result<bool, CliError> {
    let db_version = db.session_state_version(&resolved.state.session_id)?;
    let file_version = i64::try_from(resolved.state.state_version).unwrap_or(i64::MAX);
    Ok(db_version.is_none_or(|version| version < file_version))
}

fn background_session_candidate(
    db: &super::db::DaemonDb,
    resolved: &super::index::ResolvedSession,
) -> BackgroundSessionCandidate {
    match session_import_required(db, resolved) {
        Ok(false) => BackgroundSessionCandidate::Skip,
        Ok(true) => BackgroundSessionCandidate::Prepare,
        Err(error) => {
            log_background_session_version_check_error(&error, resolved);
            BackgroundSessionCandidate::Failed
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_background_session_prepare_error(
    error: &CliError,
    resolved: &super::index::ResolvedSession,
) {
    tracing::warn!(
        %error,
        session_id = %resolved.state.session_id,
        "background session prepare failed"
    );
}

fn prepared_session_import_required(
    db: &super::db::DaemonDb,
    prepared: &super::db::PreparedSessionResync,
) -> Option<bool> {
    session_import_required(db, &prepared.resolved)
        .inspect_err(|error| log_background_session_version_check_error(error, &prepared.resolved))
        .ok()
}

fn import_prepared_background_session(
    db: &super::db::DaemonDb,
    prepared: &super::db::PreparedSessionResync,
) -> BackgroundSessionImportOutcome {
    if let Err(error) = db.apply_prepared_session_resync(prepared) {
        log_background_session_import_error(&error, prepared);
        return BackgroundSessionImportOutcome::Failed;
    }
    BackgroundSessionImportOutcome::Imported
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_background_session_version_check_error(
    error: &CliError,
    resolved: &super::index::ResolvedSession,
) {
    tracing::warn!(
        %error,
        session_id = %resolved.state.session_id,
        "background session version check failed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_background_session_import_error(
    error: &CliError,
    prepared: &super::db::PreparedSessionResync,
) {
    tracing::warn!(
        %error,
        session_id = %prepared.resolved.state.session_id,
        "background session import failed"
    );
}

fn spawn_background_diagnostics(db: Option<Arc<Mutex<super::db::DaemonDb>>>) {
    let Some(db) = db else {
        return;
    };
    tokio::spawn(async move {
        let _ = spawn_blocking(move || {
            let Ok(db_guard) = db.lock() else {
                return;
            };
            let _ = db_guard.cache_startup_diagnostics();
        })
        .await;
    });
}

fn open_daemon_db(path: &Path) -> Option<super::db::DaemonDb> {
    super::db::DaemonDb::open(path)
        .inspect_err(|error| {
            let message = format!("failed to open daemon database: {error}");
            let _ = state::append_event("warn", &message);
        })
        .ok()
}

/// Build a point-in-time daemon status report.
///
/// Uses the daemon `SQLite` database (WAL mode, safe for concurrent offline
/// reads) when available, falling back to file-based discovery.
///
/// # Errors
/// Returns `CliError` on discovery failures.
pub fn status_report() -> Result<DaemonStatusReport, CliError> {
    let db_path = state::daemon_root().join("harness.db");
    let db = super::db::DaemonDb::open(&db_path).ok();

    let (project_count, worktree_count, session_count) = if let Some(ref db) = db {
        db.health_counts()?
    } else {
        let projects = snapshot::project_summaries()?;
        let sessions = snapshot::session_summaries(true)?;
        let worktree_count = projects.iter().map(|project| project.worktrees.len()).sum();
        (projects.len(), worktree_count, sessions.len())
    };

    Ok(DaemonStatusReport {
        manifest: state::load_running_manifest()?,
        launch_agent: launchd::launch_agent_status(),
        project_count,
        worktree_count,
        session_count,
        diagnostics: state::diagnostics()?,
    })
}

/// Build the daemon health response exposed on `/v1/health`.
///
/// # Errors
/// Returns [`CliError`] on discovery failures.
pub fn health_response(
    manifest: &DaemonManifest,
    db: Option<&super::db::DaemonDb>,
) -> Result<HealthResponse, CliError> {
    let (project_count, worktree_count, session_count) = if let Some(db) = db {
        db.health_counts()?
    } else {
        index::fast_counts()
    };
    Ok(HealthResponse {
        status: "ok".into(),
        version: manifest.version.clone(),
        pid: manifest.pid,
        endpoint: manifest.endpoint.clone(),
        started_at: manifest.started_at.clone(),
        log_level: current_log_level(),
        project_count,
        worktree_count,
        session_count,
    })
}

/// Build a richer diagnostics report for the daemon preferences screen.
///
/// # Errors
/// Returns `CliError` when daemon state cannot be loaded.
pub fn diagnostics_report(
    db: Option<&super::db::DaemonDb>,
) -> Result<DaemonDiagnosticsReport, CliError> {
    let manifest = state::load_manifest()?.map(|mut m| {
        if let Ok(live_bridge) = bridge::host_bridge_manifest() {
            m.host_bridge = live_bridge;
        }
        m
    });
    let health = manifest
        .as_ref()
        .map(|manifest| health_response(manifest, db))
        .transpose()?;

    if let Some(db) = db {
        return diagnostics_from_db(db, manifest, health);
    }

    Ok(DaemonDiagnosticsReport {
        health,
        manifest,
        launch_agent: launchd::launch_agent_status(),
        workspace: state::diagnostics()?,
        recent_events: state::read_recent_events(16)?,
    })
}

fn diagnostics_from_db(
    db: &super::db::DaemonDb,
    manifest: Option<DaemonManifest>,
    health: Option<HealthResponse>,
) -> Result<DaemonDiagnosticsReport, CliError> {
    let launch_agent = db
        .load_cached_launch_agent_status()?
        .unwrap_or_else(launchd::launch_agent_status);
    let workspace = match db.load_cached_workspace_diagnostics()? {
        Some(cached) => cached,
        None => state::diagnostics()?,
    };
    let recent_events = db.load_recent_daemon_events(16)?;

    Ok(DaemonDiagnosticsReport {
        health,
        manifest,
        launch_agent,
        workspace,
        recent_events,
    })
}

/// Request graceful daemon shutdown.
///
/// # Errors
/// Returns `CliError` when the shutdown signal is unavailable.
pub fn request_shutdown() -> Result<DaemonControlResponse, CliError> {
    let Some(shutdown_tx) = SHUTDOWN_SIGNAL.get() else {
        return Err(CliErrorKind::workflow_io("daemon shutdown channel unavailable").into());
    };

    shutdown_tx
        .send(true)
        .map_err(|error| CliErrorKind::workflow_io(format!("signal daemon shutdown: {error}")))?;
    state::append_event("info", "daemon shutdown requested")?;
    Ok(DaemonControlResponse {
        status: "stopping".into(),
    })
}

const VALID_LOG_LEVELS: &[&str] = &["trace", "debug", "info", "warn", "error"];

fn current_log_level() -> String {
    crate::log_filter_handle().map_or_else(
        || crate::DEFAULT_LOG_LEVEL.to_string(),
        |handle| {
            handle
                .with_current(|filter| {
                    let filter_string = filter.to_string();
                    for level in VALID_LOG_LEVELS {
                        if filter_string.contains(level) {
                            return (*level).to_string();
                        }
                    }
                    crate::DEFAULT_LOG_LEVEL.to_string()
                })
                .unwrap_or_else(|_| crate::DEFAULT_LOG_LEVEL.to_string())
        },
    )
}

/// Return the current daemon log level and filter directive.
///
/// # Errors
/// Returns `CliError` if the filter handle is unavailable.
pub fn get_log_level() -> Result<LogLevelResponse, CliError> {
    let handle = crate::log_filter_handle()
        .ok_or_else(|| CliErrorKind::workflow_io("log filter handle unavailable"))?;
    let filter = handle
        .with_current(ToString::to_string)
        .unwrap_or_else(|_| crate::DEFAULT_LOG_FILTER_DIRECTIVE.to_string());
    Ok(LogLevelResponse {
        level: current_log_level(),
        filter,
    })
}

fn validate_and_reload_filter(level: &str) -> Result<LogLevelResponse, CliError> {
    let handle = crate::log_filter_handle()
        .ok_or_else(|| CliErrorKind::workflow_io("log filter handle unavailable"))?;
    let directive = format!("harness={level}");
    let new_filter = tracing_subscriber::EnvFilter::new(&directive);
    handle
        .reload(new_filter)
        .map_err(|error| CliErrorKind::workflow_io(format!("reload log filter: {error}")))?;
    Ok(LogLevelResponse {
        level: level.to_string(),
        filter: directive,
    })
}

/// Update the daemon log level at runtime.
///
/// # Errors
/// Returns `CliError` on invalid level or reload failure.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub fn set_log_level(
    request: &SetLogLevelRequest,
    sender: &broadcast::Sender<StreamEvent>,
) -> Result<LogLevelResponse, CliError> {
    let level = request.level.to_lowercase();
    if !VALID_LOG_LEVELS.contains(&level.as_str()) {
        return Err(CliErrorKind::workflow_parse(format!(
            "invalid log level '{}', expected one of: {}",
            request.level,
            VALID_LOG_LEVELS.join(", ")
        ))
        .into());
    }

    let response = validate_and_reload_filter(&level)?;

    let payload = serde_json::to_value(&response).unwrap_or_default();
    let event = StreamEvent {
        event: "log_level_changed".into(),
        recorded_at: utc_now(),
        session_id: None,
        payload,
    };
    let _ = sender.send(event);

    let _ = state::append_event("info", &format!("log level changed to {level}"));
    tracing::info!(%level, "daemon log level changed");

    Ok(response)
}

/// List discovered projects known to the daemon.
///
/// # Errors
/// Returns [`CliError`] on project discovery failures.
pub fn list_projects(db: Option<&super::db::DaemonDb>) -> Result<Vec<ProjectSummary>, CliError> {
    if let Some(db) = db {
        return db.list_project_summaries();
    }
    snapshot::project_summaries()
}

/// List discovered sessions across all indexed projects.
///
/// # Errors
/// Returns [`CliError`] on session discovery failures.
pub fn list_sessions(
    include_all: bool,
    db: Option<&super::db::DaemonDb>,
) -> Result<Vec<SessionSummary>, CliError> {
    reconcile_active_session_liveness_for_reads(include_all, db)?;
    if let Some(db) = db {
        return db.list_session_summaries_full();
    }
    snapshot::session_summaries(include_all)
}

/// Load a single session detail snapshot.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub fn session_detail(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    reconcile_session_liveness_for_read(session_id, db)?;
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return snapshot::session_detail_from_resolved_with_db(&resolved, db);
    }
    snapshot::session_detail(session_id)
}

/// Load a merged session timeline.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
pub fn session_timeline(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<Vec<TimelineEntry>, CliError> {
    session_timeline_with_scope(session_id, timeline::TimelinePayloadScope::Full, db)
}

/// Load a merged session timeline with caller-selected payload detail.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
pub(crate) fn session_timeline_with_scope(
    session_id: &str,
    payload_scope: timeline::TimelinePayloadScope,
    db: Option<&super::db::DaemonDb>,
) -> Result<Vec<TimelineEntry>, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return timeline::session_timeline_from_resolved_with_db_scope(
            &resolved,
            db,
            payload_scope,
        );
    }
    timeline::session_timeline_with_scope(session_id, payload_scope)
}

/// Load a session timeline window with metadata for incremental clients.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
pub(crate) fn session_timeline_window(
    session_id: &str,
    request: &TimelineWindowRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<TimelineWindowResponse, CliError> {
    if let Some(db) = db
        && let Some(response) = db.load_session_timeline_window(session_id, request)?
    {
        return Ok(response);
    }
    let payload_scope = match request.scope.as_deref() {
        Some("summary") => timeline::TimelinePayloadScope::Summary,
        _ => timeline::TimelinePayloadScope::Full,
    };
    let entries = session_timeline_with_scope(session_id, payload_scope, db)?;
    build_timeline_window_response(entries, request)
}

fn build_timeline_window_response(
    entries: Vec<TimelineEntry>,
    request: &TimelineWindowRequest,
) -> Result<TimelineWindowResponse, CliError> {
    let total_count = entries.len();
    let revision = i64::try_from(total_count).map_err(|error| {
        CliErrorKind::workflow_parse(format!("timeline revision overflow: {error}"))
    })?;
    let limit = request.limit.unwrap_or(total_count).max(1);

    if request.known_revision == Some(revision)
        && request.before.is_none()
        && request.after.is_none()
    {
        return Ok(TimelineWindowResponse {
            revision,
            total_count,
            window_start: 0,
            window_end: total_count,
            has_older: total_count > limit,
            has_newer: false,
            oldest_cursor: entries.last().map(cursor_from_entry),
            newest_cursor: entries.first().map(cursor_from_entry),
            entries: None,
            unchanged: true,
        });
    }

    let (window_start, window_entries) = if let Some(before) = &request.before {
        let start = entries
            .iter()
            .position(|entry| timeline_cursor_matches(entry, before))
            .map_or(total_count, |index| index + 1);
        let end = start.saturating_add(limit).min(total_count);
        (start, entries[start..end].to_vec())
    } else if let Some(after) = &request.after {
        let end = entries
            .iter()
            .position(|entry| timeline_cursor_matches(entry, after))
            .unwrap_or(0);
        let start = end.saturating_sub(limit);
        (start, entries[start..end].to_vec())
    } else {
        let end = limit.min(total_count);
        (0, entries[..end].to_vec())
    };

    let window_end = window_start + window_entries.len();

    Ok(TimelineWindowResponse {
        revision,
        total_count,
        window_start,
        window_end,
        has_older: window_end < total_count,
        has_newer: window_start > 0,
        oldest_cursor: window_entries.last().map(cursor_from_entry),
        newest_cursor: window_entries.first().map(cursor_from_entry),
        entries: Some(window_entries),
        unchanged: false,
    })
}

fn timeline_cursor_matches(entry: &TimelineEntry, cursor: &TimelineCursor) -> bool {
    entry.entry_id == cursor.entry_id && entry.recorded_at == cursor.recorded_at
}

fn cursor_from_entry(entry: &TimelineEntry) -> TimelineCursor {
    TimelineCursor {
        recorded_at: entry.recorded_at.clone(),
        entry_id: entry.entry_id.clone(),
    }
}

/// Load a lightweight session detail with only in-memory fields.
///
/// Returns agents and tasks from the resolved session state without any
/// database queries or filesystem I/O for signals, observer, or activity.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved.
pub fn session_detail_core(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    reconcile_session_liveness_for_read(session_id, db)?;
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return Ok(snapshot::build_session_detail_core(&resolved));
    }
    let resolved = index::resolve_session(session_id)?;
    Ok(snapshot::build_session_detail_core(&resolved))
}

/// Load the expensive session detail extensions (signals, observer, activity).
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or extension loading fails.
pub fn session_extensions(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionExtensionsPayload, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return snapshot::build_session_extensions(&resolved, Some(db));
    }
    let resolved = index::resolve_session(session_id)?;
    snapshot::build_session_extensions(&resolved, None)
}

fn reconcile_active_session_liveness_for_reads(
    _include_all: bool,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = db
        .list_session_summaries()?
        .into_iter()
        .filter(|state| {
            state.status == SessionStatus::Active && state.metrics.active_agent_count > 0
        })
        .map(|state| state.session_id)
        .collect();
    let stale_session_ids = stale_session_ids_for_liveness_refresh_now(session_ids, Instant::now());
    for session_id in stale_session_ids {
        if let Err(error) = reconcile_session_liveness_for_read(&session_id, Some(db)) {
            clear_session_liveness_refresh_cache_entry(&session_id);
            return Err(error);
        }
    }
    Ok(())
}

fn stale_session_ids_for_liveness_refresh(
    cache: &mut BTreeMap<String, Instant>,
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    cache.retain(|session_id, _| session_ids.contains(session_id));
    let mut stale_session_ids = Vec::new();
    for session_id in session_ids {
        let should_refresh = cache.get(&session_id).is_none_or(|last_refresh| {
            now.saturating_duration_since(*last_refresh) >= SESSION_LIVENESS_REFRESH_TTL
        });
        if should_refresh {
            cache.insert(session_id.clone(), now);
            stale_session_ids.push(session_id);
        }
    }
    stale_session_ids
}

fn stale_session_ids_for_liveness_refresh_now(
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    let cache = SESSION_LIVENESS_REFRESH_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    match cache.lock() {
        Ok(mut cache) => stale_session_ids_for_liveness_refresh(&mut cache, session_ids, now),
        Err(_) => session_ids.into_iter().collect(),
    }
}

fn clear_session_liveness_refresh_cache_entry(session_id: &str) {
    let Some(cache) = SESSION_LIVENESS_REFRESH_CACHE.get() else {
        return;
    };
    let Ok(mut cache) = cache.lock() else {
        return;
    };
    cache.remove(session_id);
}

fn reconcile_session_liveness_for_read(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    // Only reconcile when a daemon DB is available. Without a running daemon
    // there is no liveness data to compare against.
    let Some(db) = db else {
        return Ok(());
    };
    if let Some(project_dir) = liveness_project_dir(session_id, db)? {
        let result = session_service::sync_agent_liveness(session_id, &project_dir)?;
        if !result.disconnected.is_empty() || !result.idled.is_empty() {
            db.resync_session(session_id)?;
        }
    }
    Ok(())
}

fn liveness_project_dir(
    session_id: &str,
    db: &super::db::DaemonDb,
) -> Result<Option<PathBuf>, CliError> {
    let Some(resolved) = db.resolve_session(session_id)? else {
        return Ok(None);
    };
    if resolved.state.status != SessionStatus::Active {
        return Ok(None);
    }
    if !session_has_live_agents(&resolved.state) {
        return Ok(None);
    }
    let Some(project_dir) = resolved.project.project_dir else {
        return Ok(None);
    };
    if session_storage::load_state(&project_dir, session_id)?.is_none() {
        return Ok(None);
    }
    Ok(Some(project_dir))
}

fn session_has_live_agents(state: &SessionState) -> bool {
    state.agents.values().any(|agent| agent.status.is_alive())
}

/// Create a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task creation fails.
pub fn create_task(
    session_id: &str,
    request: &TaskCreateRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let spec = session_service::TaskSpec {
        title: &request.title,
        context: request.context.as_deref(),
        severity: request.severity,
        suggested_fix: request.suggested_fix.as_deref(),
        source: TaskSource::Manual,
        observe_issue_id: None,
    };

    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let item =
            session_service::apply_create_task(&mut state, &spec, &request.actor, &utc_now())?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_created(&spec, &item),
            Some(&request.actor),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    let _ =
        session_service::create_task_with_source(session_id, &spec, &request.actor, project_dir)?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Assign a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or assignment fails.
pub fn assign_task(
    session_id: &str,
    task_id: &str,
    request: &TaskAssignRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        session_service::apply_assign_task(
            &mut state,
            task_id,
            &request.agent_id,
            &request.actor,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, &request.agent_id),
            Some(&request.actor),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::assign_task(
        session_id,
        task_id,
        &request.agent_id,
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Drop a task onto an extensible target through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the drop is invalid,
/// or task-start signal delivery fails.
pub fn drop_task(
    session_id: &str,
    task_id: &str,
    request: &TaskDropRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let effects = session_service::apply_drop_task(
            &mut state,
            task_id,
            &request.target,
            request.queue_policy,
            &request.actor,
            &now,
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::drop_task(
        session_id,
        task_id,
        &request.target,
        request.queue_policy,
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Update a queued task's reassignment policy.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the task is missing,
/// or queue promotion signal delivery fails.
pub fn update_task_queue_policy(
    session_id: &str,
    task_id: &str,
    request: &TaskQueuePolicyRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let effects = session_service::apply_update_task_queue_policy(
            &mut state,
            task_id,
            request.queue_policy,
            &request.actor,
            &now,
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::update_task_queue_policy(
        session_id,
        task_id,
        request.queue_policy,
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Update a task status through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the update fails.
pub fn update_task(
    session_id: &str,
    task_id: &str,
    request: &TaskUpdateRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let from_status = session_service::apply_update_task(
            &mut state,
            task_id,
            request.status,
            request.note.as_deref(),
            &request.actor,
            &now,
        )?;
        let effects =
            session_service::apply_advance_queued_tasks(&mut state, &request.actor, &now)?;
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_status_changed(task_id, from_status, request.status),
            Some(&request.actor),
            None,
        ))?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::update_task(
        session_id,
        task_id,
        request.status,
        request.note.as_deref(),
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Record a task checkpoint through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or checkpointing fails.
pub fn checkpoint_task(
    session_id: &str,
    task_id: &str,
    request: &TaskCheckpointRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let checkpoint = session_service::apply_record_checkpoint(
            &mut state,
            task_id,
            &request.actor,
            &request.summary,
            request.progress,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_checkpoint(session_id, &checkpoint)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_checkpoint_recorded(
                task_id,
                &checkpoint.checkpoint_id,
                request.progress,
            ),
            Some(&request.actor),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    let _ = session_service::record_task_checkpoint(
        session_id,
        task_id,
        &request.actor,
        &request.summary,
        request.progress,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Change an agent role through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub fn change_role(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let from_role = session_service::apply_assign_role(
            &mut state,
            agent_id,
            request.role,
            &request.actor,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_role_changed(agent_id, from_role, request.role),
            Some(&request.actor),
            request.reason.as_deref(),
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::assign_role(
        session_id,
        agent_id,
        request.role,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Remove an agent through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the removal fails.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let leave_signal = session_service::prepare_remove_agent_leave_signal(
            &state,
            agent_id,
            &request.actor,
            &now,
        )?;
        if let Some(ref signal) = leave_signal {
            session_service::write_prepared_leave_signals(
                &project_dir,
                slice::from_ref(signal),
                "remove agent",
            )?;
        }
        session_service::apply_remove_agent(&mut state, agent_id, &request.actor, &now)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        if let Some(ref signal) = leave_signal {
            append_leave_signal_logs_to_db(
                db,
                session_id,
                &request.actor,
                slice::from_ref(signal),
            )?;
        }
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_removed(agent_id),
            Some(&request.actor),
            None,
        ))?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::remove_agent(session_id, agent_id, &request.actor, project_dir)?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Transfer session leadership through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub fn transfer_leader(
    session_id: &str,
    request: &LeaderTransferRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let plan = session_service::apply_transfer_leader(
            &mut state,
            &request.new_leader_id,
            &request.actor,
            request.reason.as_deref(),
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        append_transfer_logs_to_db(db, session_id, &request.actor, &plan)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::transfer_leader(
        session_id,
        &request.new_leader_id,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// End a session through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub fn end_session(
    session_id: &str,
    request: &SessionEndRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let leave_signals =
            session_service::prepare_end_session_leave_signals(&state, &request.actor, &now)?;
        session_service::write_prepared_leave_signals(&project_dir, &leave_signals, "end session")?;
        session_service::apply_end_session(&mut state, &request.actor, &now)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.mark_session_inactive(session_id)?;
        append_leave_signal_logs_to_db(db, session_id, &request.actor, &leave_signals)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_session_ended(),
            Some(&request.actor),
            None,
        ))?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::end_session(session_id, &request.actor, project_dir)?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Send a signal through the shared session service.
///
/// Signal files are always written to disk for runtime pickup, even in
/// the DB-direct path, because agent runtimes poll the filesystem.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or signal delivery setup fails.
pub fn send_signal(
    session_id: &str,
    request: &SignalSendRequest,
    db: Option<&super::db::DaemonDb>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        // DB-direct: apply state mutation to SQLite, then write signal file.
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let (runtime_name, target_agent_session_id) = session_service::apply_send_signal_state(
            &mut state,
            &request.agent_id,
            &request.actor,
            &now,
        )?;
        let target_tui_id = state
            .agents
            .get(&request.agent_id)
            .and_then(agent_tui_id_for_registration)
            .map(ToString::to_string);
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;

        // Write signal file for runtime pickup (always file-based).
        let signal = session_service::build_signal(
            &request.actor,
            &request.command,
            &request.message,
            request.action_hint.as_deref(),
            session_id,
            &request.agent_id,
            &now,
        );
        let runtime = agents_runtime::runtime_for_name(&runtime_name).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "unknown runtime '{runtime_name}'"
            )))
        })?;
        let signal_session_id = target_agent_session_id.as_deref().unwrap_or(session_id);
        runtime.write_signal(&project_dir, signal_session_id, &signal)?;

        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &signal.signal_id,
                &request.agent_id,
                &request.command,
            ),
            Some(&request.actor),
            None,
        ))?;
        attempt_active_signal_delivery(
            &ActiveSignalDelivery {
                session_id,
                agent_id: &request.agent_id,
                signal: &signal,
                runtime,
                project_dir: &project_dir,
                signal_session_id,
                db: Some(db),
            },
            managed_tui_wake(target_tui_id.as_deref(), agent_tui_manager),
        );
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    // File-based fallback
    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let _ = session_service::send_signal(
        session_id,
        &request.agent_id,
        &request.command,
        &request.message,
        request.action_hint.as_deref(),
        &request.actor,
        &project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

fn managed_tui_wake<'a>(
    tui_id: Option<&'a str>,
    agent_tui_manager: Option<&'a AgentTuiManagerHandle>,
) -> Option<ManagedTuiWake<'a>> {
    Some(ManagedTuiWake {
        tui_id: tui_id?,
        manager: agent_tui_manager?,
    })
}

fn attempt_active_signal_delivery(
    delivery: &ActiveSignalDelivery<'_>,
    managed_tui: Option<ManagedTuiWake<'_>>,
) {
    let Some(managed_tui) = managed_tui else {
        return;
    };

    let Some(woke_tui) = handled_active_signal_wake_result(
        delivery,
        wake_tui_for_signal(&managed_tui, delivery.signal),
    ) else {
        return;
    };

    if woke_tui {
        process_active_signal_ack(delivery);
    }
}

fn wake_tui_for_signal(
    managed_tui: &ManagedTuiWake<'_>,
    signal: &agents_runtime::signal::Signal,
) -> Result<bool, CliError> {
    let prompt = build_active_signal_prompt(signal);
    managed_tui.manager.prompt_tui(managed_tui.tui_id, &prompt)
}

fn handled_active_signal_wake_result(
    delivery: &ActiveSignalDelivery<'_>,
    wake_result: Result<bool, CliError>,
) -> Option<bool> {
    match wake_result {
        Ok(woke_tui) => Some(woke_tui),
        Err(error) => {
            warn_active_signal_wake_failure(delivery, &error);
            None
        }
    }
}

fn process_active_signal_ack(delivery: &ActiveSignalDelivery<'_>) {
    let Some(ack) = handled_active_signal_ack_wait_result(
        delivery,
        wait_for_signal_ack(
            delivery.runtime,
            delivery.project_dir,
            delivery.signal_session_id,
            &delivery.signal.signal_id,
        ),
    ) else {
        return;
    };

    record_active_signal_ack(delivery, &ack);
}

fn handled_active_signal_ack_wait_result(
    delivery: &ActiveSignalDelivery<'_>,
    ack_result: Result<Option<SignalAck>, CliError>,
) -> Option<SignalAck> {
    match ack_result {
        Ok(Some(ack)) => Some(ack),
        Ok(None) => {
            warn_active_signal_delivery_timeout(
                delivery.session_id,
                delivery.agent_id,
                &delivery.signal.signal_id,
            );
            None
        }
        Err(error) => {
            warn_active_signal_ack_wait_failure(delivery, &error);
            None
        }
    }
}

fn record_active_signal_ack(delivery: &ActiveSignalDelivery<'_>, ack: &SignalAck) {
    let Err(error) = record_signal_ack(
        delivery.session_id,
        delivery.agent_id,
        &delivery.signal.signal_id,
        ack.result,
        delivery.project_dir,
        delivery.db,
    ) else {
        return;
    };

    warn_active_signal_ack_record_failure(delivery, &error);
}

fn build_active_signal_prompt(signal: &agents_runtime::signal::Signal) -> String {
    match signal.payload.action_hint.as_deref() {
        Some(action_hint) => format!(
            "[Harness signal] {}: {} ({action_hint})",
            signal.command, signal.payload.message
        ),
        None => format!(
            "[Harness signal] {}: {}",
            signal.command, signal.payload.message
        ),
    }
}

fn wait_for_signal_ack(
    runtime: &dyn agents_runtime::AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    signal_id: &str,
) -> Result<Option<SignalAck>, CliError> {
    let deadline = Instant::now() + ACTIVE_SIGNAL_ACK_TIMEOUT;
    loop {
        if let Some(ack) = runtime
            .read_acknowledgments(project_dir, signal_session_id)?
            .into_iter()
            .find(|ack| ack.signal_id == signal_id)
        {
            return Ok(Some(ack));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        thread::sleep(ACTIVE_SIGNAL_ACK_POLL_INTERVAL);
    }
}

fn warn_active_signal_delivery_timeout(session_id: &str, agent_id: &str, signal_id: &str) {
    state::append_event_best_effort(
        "warn",
        &active_signal_delivery_timeout_message(session_id, agent_id, signal_id),
    );
    log_active_signal_delivery_timeout(session_id, agent_id, signal_id);
}

fn active_signal_delivery_timeout_message(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
) -> String {
    format!(
        "session '{session_id}' signal '{signal_id}' to agent '{agent_id}' stayed pending after active TUI wake-up for {} ms",
        ACTIVE_SIGNAL_ACK_TIMEOUT.as_millis()
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn warn_active_signal_wake_failure(delivery: &ActiveSignalDelivery<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = delivery.session_id,
        agent_id = delivery.agent_id,
        signal_id = %delivery.signal.signal_id,
        "failed to wake managed TUI for active signal delivery"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn warn_active_signal_ack_wait_failure(delivery: &ActiveSignalDelivery<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = delivery.session_id,
        agent_id = delivery.agent_id,
        signal_id = %delivery.signal.signal_id,
        "failed while waiting for active signal acknowledgment"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn warn_active_signal_ack_record_failure(delivery: &ActiveSignalDelivery<'_>, error: &CliError) {
    tracing::warn!(
        %error,
        session_id = delivery.session_id,
        agent_id = delivery.agent_id,
        signal_id = %delivery.signal.signal_id,
        "failed to record actively delivered signal acknowledgment"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn log_active_signal_delivery_timeout(session_id: &str, agent_id: &str, signal_id: &str) {
    tracing::warn!(
        session_id,
        agent_id,
        signal_id,
        timeout_ms = ACTIVE_SIGNAL_ACK_TIMEOUT.as_millis(),
        "active TUI signal delivery timed out"
    );
}

fn agent_tui_id_for_registration(agent: &AgentRegistration) -> Option<&str> {
    agent.capabilities.iter().find_map(|capability| {
        capability
            .strip_prefix("agent-tui:")
            .filter(|value| !value.trim().is_empty())
    })
}

/// Cancel a pending signal by writing a rejected acknowledgment.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the signal is not
/// pending, or ack persistence fails.
pub fn cancel_signal(
    session_id: &str,
    request: &super::protocol::SignalCancelRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = if let Some(db) = db
        && let Some(dir) = db.project_dir_for_session(session_id)?
    {
        PathBuf::from(dir)
    } else {
        let resolved = index::resolve_session(session_id)?;
        effective_project_dir(&resolved).to_path_buf()
    };

    session_service::cancel_signal(
        session_id,
        &request.agent_id,
        &request.signal_id,
        &request.actor,
        &project_dir,
    )?;

    if let Some(db) = db {
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
    } else {
        sync_after_mutation(db, session_id);
    }
    session_detail(session_id, db)
}

/// Start a new session, writing directly to `SQLite` when a DB is available.
///
/// Falls back to file-based session creation when `db` is `None`.
///
/// # Errors
/// Returns `CliError` when the runtime is unknown or DB operations fail.
pub fn start_session_direct(
    request: &super::protocol::SessionStartRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
    let runtime_name = &request.runtime;
    let leader_runtime = resolve_hook_agent(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "session start requires a known runtime, got '{runtime_name}'"
        )))
    })?;

    let project_dir = Path::new(&request.project_dir);
    let leader_agent_session_id =
        agents_service::resolve_known_session_id(leader_runtime, project_dir, None)?;
    let now = utc_now();
    let session_id = request
        .session_id
        .clone()
        .unwrap_or_else(|| format!("sess-{}", chrono::Utc::now().format("%Y%m%d%H%M%S%f")));

    let state = session_service::build_new_session(
        &request.context,
        &request.title,
        &session_id,
        runtime_name,
        leader_agent_session_id.as_deref(),
        &now,
    );

    if let Some(db) = db {
        let project_id = ensure_project_registered(db, project_dir)?;
        db.create_session_record(&project_id, &state)?;
        let leader_id = state.leader_id.as_deref().unwrap_or("");
        db.append_log_entry(&build_log_entry(
            &session_id,
            session_service::log_session_started(&request.title, &request.context),
            Some(leader_id),
            None,
        ))?;
        db.bump_change(&session_id)?;
        db.bump_change("global")?;
        return Ok(state);
    }

    // File-based fallback
    session_service::start_session(
        &request.context,
        &request.title,
        project_dir,
        Some(runtime_name),
        Some(&session_id),
    )
}

fn ensure_project_registered(
    db: &super::db::DaemonDb,
    project_dir: &Path,
) -> Result<String, CliError> {
    session_storage::record_project_origin(project_dir)?;
    let project = index::discovered_project_for_checkout(project_dir);
    db.sync_project(&project)?;
    Ok(project.project_id)
}

/// Join an existing session, writing directly to `SQLite` when a DB is available.
///
/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or DB operations fail.
pub fn join_session_direct(
    session_id: &str,
    request: &super::protocol::SessionJoinRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
    if request.role == SessionRole::Leader {
        return Err(CliErrorKind::session_agent_conflict(
            "daemon join requests cannot claim the leader role",
        )
        .into());
    }
    let display_name = request
        .name
        .clone()
        .unwrap_or_else(|| format!("{} {:?}", request.runtime, request.role).to_lowercase());

    let project_dir = Path::new(&request.project_dir);
    let agent_session_id = resolve_hook_agent(&request.runtime)
        .and_then(|rt| agents_service::resolve_known_session_id(rt, project_dir, None).ok())
        .flatten();

    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let agent_id = session_service::apply_join_session(
            &mut state,
            &display_name,
            &request.runtime,
            request.role,
            &request.capabilities,
            agent_session_id.as_deref(),
            &now,
            request.persona.as_deref(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_joined(&agent_id, request.role, &request.runtime),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return Ok(state);
    }

    // File-based fallback
    session_service::join_session(
        session_id,
        request.role,
        &request.runtime,
        &request.capabilities,
        request.name.as_deref(),
        project_dir,
        request.persona.as_deref(),
    )
}

/// Mark a session agent as disconnected, writing directly to `SQLite` when a
/// DB is available.
///
/// Returns `Ok(false)` when the agent is already non-live or missing.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or persisted.
pub fn disconnect_agent_direct(
    session_id: &str,
    agent_id: &str,
    reason: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<bool, CliError> {
    let Some(db) = db else {
        return Ok(false);
    };
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return Ok(false);
    };

    let now = utc_now();
    if !session_service::apply_agent_disconnected(&mut state, agent_id, &now) {
        return Ok(false);
    }

    persist_disconnect(db, session_id, agent_id, reason, &state)?;
    Ok(true)
}

fn persist_disconnect(
    db: &super::db::DaemonDb,
    session_id: &str,
    agent_id: &str,
    reason: &str,
    state: &SessionState,
) -> Result<(), CliError> {
    let project_id = db
        .project_id_for_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    db.save_session_state(&project_id, state)?;
    db.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_agent_disconnected(agent_id, reason),
        None,
        None,
    ))?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(())
}

/// Record a signal acknowledgment, delegating to the session service.
///
/// # Errors
/// Returns `CliError` on log read/write failures.
pub fn record_signal_ack_direct(
    session_id: &str,
    request: &super::protocol::SignalAckRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    let project_dir = Path::new(&request.project_dir);
    record_signal_ack(
        session_id,
        &request.agent_id,
        &request.signal_id,
        request.result,
        project_dir,
        db,
    )
}

/// Start or refresh the daemon-owned session observation loop.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or observe fails.
pub fn observe_session(
    session_id: &str,
    request: Option<&ObserveSessionRequest>,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let actor_id = request
        .and_then(|request| request.actor.as_deref())
        .filter(|value| !value.trim().is_empty());

    // Resolve project_dir from the DB when available, falling back to
    // file-based discovery.
    let project_dir = if let Some(db) = db
        && let Some(dir) = db.project_dir_for_session(session_id)?
    {
        PathBuf::from(dir)
    } else {
        let resolved = index::resolve_session(session_id)?;
        effective_project_dir(&resolved).to_path_buf()
    };

    let _ = session_observe::run_session_observe(session_id, &project_dir, actor_id)?;
    let _ = start_daemon_observe_loop(session_id, &project_dir, actor_id);
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Build a `ready` stream event for SSE subscribers.
///
/// # Panics
/// Panics if the trivial `ReadyEventPayload` cannot be serialized to JSON.
pub fn ready_event(session_id: Option<&str>) -> StreamEvent {
    StreamEvent {
        event: "ready".to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serde_json::to_value(ReadyEventPayload { ok: true })
            .expect("serialize daemon ready payload"),
    }
}

/// Build the events every global stream subscriber receives immediately.
///
/// This closes the subscription gap between the monitor's last explicit
/// refresh and the moment the daemon marks the stream as subscribed.
#[must_use]
pub fn global_stream_initial_events(db: Option<&super::db::DaemonDb>) -> Vec<StreamEvent> {
    let mut events = vec![ready_event(None)];
    if let Ok(event) = sessions_updated_event(db) {
        events.push(event);
    }
    events
}

/// Build the events every per-session stream subscriber receives immediately.
///
/// This gives reconnecting clients a fresh selected-session snapshot even when
/// the mutation broadcast happened before the stream subscription became live.
#[must_use]
pub fn session_stream_initial_events(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Vec<StreamEvent> {
    let mut events = vec![ready_event(Some(session_id))];
    if let Ok(event) = session_updated_core_event(session_id, db) {
        events.push(event);
    }
    if let Ok(event) = session_extensions_event(session_id, db) {
        events.push(event);
    }
    events
}

/// Build a `sessions_updated` stream event with current project and session lists.
///
/// # Errors
/// Returns `CliError` when project or session discovery fails.
pub fn sessions_updated_event(db: Option<&super::db::DaemonDb>) -> Result<StreamEvent, CliError> {
    let payload = SessionsUpdatedPayload {
        projects: list_projects(db)?,
        sessions: list_sessions(true, db)?,
    };
    stream_event("sessions_updated", None, payload)
}

/// Build a `session_updated` stream event with live session detail only.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or serialized.
pub fn session_updated_event(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<StreamEvent, CliError> {
    let payload = SessionUpdatedPayload {
        detail: session_detail(session_id, db)?,
        timeline: None,
        extensions_pending: false,
    };
    stream_event("session_updated", Some(session_id), payload)
}

/// Build a lightweight `session_updated` stream event using core-only detail.
///
/// Signals, observer, and agent activity are omitted. The `extensions_pending`
/// flag tells the client that a follow-up `session_extensions` event will arrive.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or serialized.
pub fn session_updated_core_event(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<StreamEvent, CliError> {
    let payload = SessionUpdatedPayload {
        detail: session_detail_core(session_id, db)?,
        timeline: None,
        extensions_pending: true,
    };
    stream_event("session_updated", Some(session_id), payload)
}

/// Build a `session_extensions` stream event with the expensive detail fields.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or extensions fail to load.
pub fn session_extensions_event(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<StreamEvent, CliError> {
    let payload = session_extensions(session_id, db)?;
    stream_event("session_extensions", Some(session_id), payload)
}

pub fn broadcast_sessions_updated(
    sender: &broadcast::Sender<StreamEvent>,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(sender, sessions_updated_event(db), "sessions_updated", None);
}

pub fn broadcast_session_updated(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(
        sender,
        session_updated_event(session_id, db),
        "session_updated",
        Some(session_id),
    );
}

/// Broadcast a lightweight session update with core-only detail.
///
/// The `extensions_pending` flag tells clients that a follow-up
/// `session_extensions` event will arrive with signals, observer, and activity.
pub fn broadcast_session_updated_core(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(
        sender,
        session_updated_core_event(session_id, db),
        "session_updated",
        Some(session_id),
    );
}

/// Broadcast the expensive session detail extensions.
pub fn broadcast_session_extensions(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(
        sender,
        session_extensions_event(session_id, db),
        "session_extensions",
        Some(session_id),
    );
}

pub fn broadcast_session_snapshot(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_sessions_updated(sender, db);
    broadcast_session_updated_core(sender, session_id, db);
    broadcast_session_extensions(sender, session_id, db);
}

fn stream_event<T: Serialize>(
    event: &str,
    session_id: Option<&str>,
    payload: T,
) -> Result<StreamEvent, CliError> {
    Ok(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serialize_event_payload(payload, event)?,
    })
}

fn serialize_event_payload<T: Serialize>(payload: T, event: &str) -> Result<Value, CliError> {
    serde_json::to_value(payload).map_err(|error| {
        CliErrorKind::workflow_io(format!("serialize daemon push '{event}': {error}")).into()
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn broadcast_event(
    sender: &broadcast::Sender<StreamEvent>,
    event: Result<StreamEvent, CliError>,
    event_name: &str,
    session_id: Option<&str>,
) {
    match event {
        Ok(payload) => {
            let receiver_count = sender.receiver_count();
            let _ = sender.send(payload);
            tracing::debug!(
                event = event_name,
                session_id = session_id.unwrap_or("-"),
                receiver_count,
                "broadcast event sent"
            );
        }
        Err(error) => {
            warn_broadcast_failure(&error.to_string(), event_name, session_id.unwrap_or("-"));
        }
    }
}

/// Emit a warning for a failed broadcast event.
///
/// Uses `tracing::Event::dispatch` directly because the `tracing::warn!`
/// macro expansion generates cognitive complexity 8 in clippy's analysis,
/// which exceeds the pedantic threshold of 7. See tokio-rs/tracing#553.
fn warn_broadcast_failure(error_message: &str, event_name: &str, session: &str) {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "warn",
        "harness::daemon::service",
        Level::WARN,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let message = format!(
        "failed to build daemon push event '{event_name}': {error_message} (session={session})"
    );
    let values: &[Option<&dyn Value>] = &[Some(&message.as_str())];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}

/// Re-sync a session from files into `SQLite` after a file-based mutation.
/// Silently ignores errors since the file write already succeeded and the
/// watch loop will eventually catch up.
fn sync_after_mutation(db: Option<&super::db::DaemonDb>, session_id: &str) {
    if let Some(db) = db {
        let _ = db.resync_session(session_id);
    }
}

fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return session_service::record_signal_acknowledgment(
            session_id,
            agent_id,
            signal_id,
            result,
            project_dir,
        );
    };
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return session_service::record_signal_acknowledgment(
            session_id,
            agent_id,
            signal_id,
            result,
            project_dir,
        );
    };

    let already_logged = db.load_session_log(session_id)?.into_iter().any(|entry| {
        matches!(
            entry.transition,
            SessionTransition::SignalAcknowledged { signal_id: ref existing, .. }
                if existing == signal_id
        )
    });
    if already_logged {
        return Ok(());
    }

    let now = utc_now();
    let signal = session_service::load_signal_record_for_agent_from_state(
        &state,
        agent_id,
        signal_id,
        project_dir,
    )?;
    let result = signal.as_ref().map_or(result, |signal| {
        session_service::normalize_signal_ack_result(&signal.signal, result)
    });
    let mut started_task = None;

    if let Some(signal) = signal.as_ref() {
        started_task = session_service::apply_signal_ack_result(
            &mut state,
            agent_id,
            &signal.signal,
            result,
            &now,
        );
        session_service::refresh_session(&mut state, &now);
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
    }

    if let Some(task_id) = started_task.as_deref() {
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, agent_id),
            Some(agent_id),
            None,
        ))?;
    }

    db.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_signal_acknowledged(signal_id, agent_id, result),
        Some(agent_id),
        None,
    ))?;
    refresh_signal_index_for_db(db, session_id)?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(())
}

fn reconcile_expired_pending_signals_for_db(
    session_id: &str,
    db: &super::db::DaemonDb,
) -> Result<(), CliError> {
    let Some(state) = db.load_session_state_for_mutation(session_id)? else {
        return Ok(());
    };
    let Some(project_dir) = db.project_dir_for_session(session_id)? else {
        return Ok(());
    };
    let project_dir = PathBuf::from(project_dir);
    let expired = session_service::collect_expired_pending_signals_for_state(&state, &project_dir)?;
    for signal in expired {
        let ack = SignalAck {
            signal_id: signal.signal.signal_id.clone(),
            acknowledged_at: utc_now(),
            result: AckResult::Expired,
            agent: signal.signal_session_id.clone(),
            session_id: session_id.to_string(),
            details: Some("expired before agent acknowledged delivery".to_string()),
        };
        write_signal_ack(&signal.signal_dir, &ack)?;
        record_signal_ack(
            session_id,
            &signal.agent_id,
            &signal.signal.signal_id,
            AckResult::Expired,
            &project_dir,
            Some(db),
        )?;
    }
    Ok(())
}

fn refresh_signal_index_for_db(db: &super::db::DaemonDb, session_id: &str) -> Result<(), CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(session_id, &signals)
}

fn append_leave_signal_logs_to_db(
    db: &super::db::DaemonDb,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            Some(actor_id),
            None,
        ))?;
    }
    Ok(())
}

fn append_transfer_logs_to_db(
    db: &super::db::DaemonDb,
    session_id: &str,
    actor_id: &str,
    plan: &session_service::LeaderTransferPlan,
) -> Result<(), CliError> {
    if let Some(ref request) = plan.pending_request {
        db.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id.clone(),
                to: request.new_leader_id.clone(),
            },
            Some(actor_id),
            request.reason.as_deref(),
        ))?;
        return Ok(());
    }
    if let Some(ref outcome) = plan.outcome {
        if outcome.log_request_before_transfer {
            db.append_log_entry(&build_log_entry(
                session_id,
                SessionTransition::LeaderTransferRequested {
                    from: outcome.old_leader.clone(),
                    to: outcome.new_leader_id.clone(),
                },
                Some(actor_id),
                outcome.reason.as_deref(),
            ))?;
        }
        if let Some(ref confirmed_by) = outcome.confirmed_by {
            db.append_log_entry(&build_log_entry(
                session_id,
                SessionTransition::LeaderTransferConfirmed {
                    from: outcome.old_leader.clone(),
                    to: outcome.new_leader_id.clone(),
                    confirmed_by: confirmed_by.clone(),
                },
                Some(confirmed_by),
                outcome.reason.as_deref(),
            ))?;
        }
        db.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferred {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        ))?;
    }
    Ok(())
}

fn resolve_hook_agent(runtime_name: &str) -> Option<HookAgent> {
    match runtime_name {
        "claude" => Some(HookAgent::Claude),
        "copilot" => Some(HookAgent::Copilot),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

fn session_not_found(session_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
}

fn project_dir_for_db_session(
    db: &super::db::DaemonDb,
    session_id: &str,
) -> Result<PathBuf, CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    Ok(effective_project_dir(&resolved).to_path_buf())
}

fn write_task_start_signals(
    project_dir: &Path,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    let signals: Vec<_> = effects
        .iter()
        .filter_map(|effect| match effect {
            session_service::TaskDropEffect::Started(signal) => Some(signal.as_ref().clone()),
            session_service::TaskDropEffect::Queued { .. } => None,
        })
        .collect();
    session_service::write_prepared_task_start_signals(project_dir, &signals)
}

fn append_task_drop_effect_logs(
    db: &super::db::DaemonDb,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            session_service::TaskDropEffect::Started(signal) => {
                db.append_log_entry(&build_log_entry(
                    session_id,
                    session_service::log_signal_sent(
                        &signal.signal.signal_id,
                        &signal.agent_id,
                        &signal.signal.command,
                    ),
                    Some(actor_id),
                    None,
                ))?;
            }
            session_service::TaskDropEffect::Queued { task_id, agent_id } => {
                db.append_log_entry(&build_log_entry(
                    session_id,
                    session_service::log_task_queued(task_id, agent_id),
                    Some(actor_id),
                    None,
                ))?;
            }
        }
    }
    Ok(())
}

fn build_log_entry(
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> SessionLogEntry {
    SessionLogEntry {
        sequence: 0,
        recorded_at: utc_now(),
        session_id: session_id.to_string(),
        transition,
        actor_id: actor_id.map(ToString::to_string),
        reason: reason.map(ToString::to_string),
    }
}

/// Return the original project directory when available, falling back to the
/// context root. This is safe because `project_context_dir` is idempotent
/// for paths already under the projects root.
fn effective_project_dir(resolved: &ResolvedSession) -> &Path {
    resolved
        .project
        .project_dir
        .as_deref()
        .unwrap_or(&resolved.project.context_root)
}

fn start_daemon_observe_loop(
    session_id: &str,
    project_dir: &Path,
    actor_id: Option<&str>,
) -> ObserveLoopState {
    let Some(runtime) = OBSERVE_RUNTIME.get().cloned() else {
        return ObserveLoopState::Unavailable;
    };
    let Ok(handle) = Handle::try_current() else {
        return ObserveLoopState::Unavailable;
    };
    let request = ObserveLoopRequest::new(actor_id);
    let session_id = session_id.to_string();
    let project_dir = project_dir.to_path_buf();

    let (state, stale_handle) = {
        let Ok(mut running_sessions) = runtime.running_sessions.lock() else {
            return ObserveLoopState::Unavailable;
        };
        if let Some(existing) = running_sessions.get(&session_id)
            && existing.request == request
        {
            return ObserveLoopState::AlreadyRunning;
        }

        let (stale_handle, generation) =
            running_sessions
                .get(&session_id)
                .map_or((None, 1), |existing| {
                    (
                        Some(existing.abort_handle.clone()),
                        existing.generation.saturating_add(1),
                    )
                });
        let state = if stale_handle.is_some() {
            ObserveLoopState::Restarted
        } else {
            ObserveLoopState::Started
        };
        let registration_session_id = session_id.clone();
        let abort_handle = spawn_daemon_observe_loop(
            &handle,
            runtime.clone(),
            session_id,
            project_dir,
            request.actor_id.clone(),
            generation,
        );
        running_sessions.insert(
            registration_session_id,
            ObserveLoopRegistration {
                request,
                generation,
                abort_handle,
            },
        );
        (state, stale_handle)
    };

    if let Some(stale_handle) = stale_handle {
        stale_handle.abort();
    }
    state
}

fn spawn_daemon_observe_loop(
    handle: &Handle,
    runtime: DaemonObserveRuntime,
    session_id: String,
    project_dir: PathBuf,
    actor_id: Option<String>,
    generation: u64,
) -> AbortHandle {
    let join_handle = handle.spawn(async move {
        let cleanup_session_id = session_id.clone();
        let result =
            run_daemon_observe_task(session_id, project_dir, runtime.poll_interval, actor_id).await;
        if let Err(error) = result {
            tracing::warn!(
                %error,
                session_id = cleanup_session_id,
                "daemon observe loop exited with error"
            );
        }
        if let Ok(mut running_sessions) = runtime.running_sessions.lock()
            && running_sessions
                .get(&cleanup_session_id)
                .is_some_and(|registration| registration.generation == generation)
        {
            running_sessions.remove(&cleanup_session_id);
        }
        let db_guard = runtime.db.get().and_then(|db| db.lock().ok());
        let db_ref = db_guard.as_deref();
        sync_after_mutation(db_ref, &cleanup_session_id);
        broadcast_session_snapshot(&runtime.sender, &cleanup_session_id, db_ref);
    });
    join_handle.abort_handle()
}

async fn run_daemon_observe_task(
    session_id: String,
    project_dir: PathBuf,
    poll_interval: Duration,
    actor_id: Option<String>,
) -> Result<i32, CliError> {
    run_daemon_observe_task_with(
        session_id,
        project_dir,
        poll_interval,
        actor_id,
        |session_id, project_dir, poll_interval, actor_id| async move {
            session_observe::execute_session_watch_async(
                &session_id,
                &project_dir,
                poll_interval.as_secs().max(1),
                false,
                actor_id.as_deref(),
            )
            .await
        },
    )
    .await
}

async fn run_daemon_observe_task_with<F, Fut>(
    session_id: String,
    project_dir: PathBuf,
    poll_interval: Duration,
    actor_id: Option<String>,
    observe_task: F,
) -> Result<i32, CliError>
where
    F: FnOnce(String, PathBuf, Duration, Option<String>) -> Fut + Send,
    Fut: Future<Output = Result<i32, CliError>> + Send,
{
    observe_task(session_id, project_dir, poll_interval, actor_id).await
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::{Arc, Mutex, OnceLock};

    use fs_err as fs;
    use tempfile::tempdir;
    use tokio::sync::broadcast;

    use crate::agents::runtime;
    use crate::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiStartRequest};
    use crate::daemon::protocol::{SessionUpdatedPayload, SessionsUpdatedPayload};
    use crate::hooks::adapters::HookAgent;
    use crate::session::{
        service as session_service,
        types::{AgentStatus, SessionRole, SessionSignalStatus, SessionStatus},
    };
    use crate::workspace::project_context_dir;
    use harness_testkit::with_isolated_harness_env;

    fn install_test_observe_runtime(poll_interval: Duration) {
        let (sender, _) = broadcast::channel(8);
        let _ = OBSERVE_RUNTIME.set(DaemonObserveRuntime {
            sender,
            poll_interval,
            running_sessions: Arc::default(),
            db: Arc::new(OnceLock::new()),
        });
    }

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
                let project = tmp.path().join("project");
                fs::create_dir_all(&project).expect("create project dir");
                let status = Command::new("git")
                    .arg("init")
                    .arg("-q")
                    .arg(&project)
                    .status()
                    .expect("git init");
                assert!(status.success(), "git init should succeed");
                test_fn(&project);
            });
        });
    }

    fn append_project_ledger_entry(project_dir: &Path) {
        let ledger_path = project_context_dir(project_dir)
            .join("agents")
            .join("ledger")
            .join("events.jsonl");
        fs::create_dir_all(ledger_path.parent().expect("ledger dir")).expect("create ledger dir");
        fs::write(
            &ledger_path,
            format!(
                "{{\"sequence\":1,\"recorded_at\":\"2026-03-28T12:00:00Z\",\"cwd\":\"{}\"}}\n",
                project_dir.display()
            ),
        )
        .expect("write ledger");
    }

    fn write_agent_log(project_dir: &Path, runtime: HookAgent, session_id: &str, text: &str) {
        let log_path = project_context_dir(project_dir)
            .join("agents/sessions")
            .join(runtime::runtime_for(runtime).name())
            .join(session_id)
            .join("raw.jsonl");
        fs::create_dir_all(log_path.parent().expect("agent log dir")).expect("create log dir");
        fs::write(
            log_path,
            format!(
                "{{\"timestamp\":\"2026-03-28T12:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{text}\"}}}}\n"
            ),
        )
        .expect("write log");
    }

    fn write_agent_log_file(project: &Path, runtime: &str, session_id: &str) -> PathBuf {
        let log_path = crate::workspace::project_context_dir(project)
            .join(format!("agents/sessions/{runtime}/{session_id}/raw.jsonl"));
        fs::create_dir_all(log_path.parent().expect("agent log dir")).expect("create log dir");
        fs::write(&log_path, "{}\n").expect("write log");
        log_path
    }

    fn set_log_mtime_seconds_ago(path: &Path, seconds: u64) {
        let old_time = std::time::SystemTime::now() - std::time::Duration::from_secs(seconds);
        std::fs::File::options()
            .write(true)
            .open(path)
            .expect("open for mtime")
            .set_times(std::fs::FileTimes::new().set_modified(old_time))
            .expect("set mtime");
    }

    #[test]
    fn session_import_required_skips_matching_db_versions() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon version skip",
                "",
                project,
                Some("claude"),
                Some("daemon-version-skip"),
            )
            .expect("start session");

            append_project_ledger_entry(project);
            let db_root = tempdir().expect("db root");
            let db = crate::daemon::db::DaemonDb::open(&db_root.path().join("harness.db"))
                .expect("open db");
            let projects = crate::daemon::index::discover_projects().expect("discover projects");
            let sessions = crate::daemon::index::discover_sessions_for(&projects, true)
                .expect("discover sessions");
            db.reconcile_sessions(&projects, &sessions)
                .expect("reconcile sessions");
            let resolved = sessions
                .into_iter()
                .find(|resolved| resolved.state.session_id == state.session_id)
                .expect("resolved session");

            assert!(
                !session_import_required(&db, &resolved).expect("version check"),
                "already indexed session should not require prepare"
            );
        });
    }

    #[test]
    fn session_import_required_detects_newer_file_versions() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon version refresh",
                "",
                project,
                Some("claude"),
                Some("daemon-version-refresh"),
            )
            .expect("start session");
            let leader_id = state.leader_id.clone().expect("leader id");

            append_project_ledger_entry(project);
            let db_root = tempdir().expect("db root");
            let db = crate::daemon::db::DaemonDb::open(&db_root.path().join("harness.db"))
                .expect("open db");
            let projects = crate::daemon::index::discover_projects().expect("discover projects");
            let sessions = crate::daemon::index::discover_sessions_for(&projects, true)
                .expect("discover sessions");
            db.reconcile_sessions(&projects, &sessions)
                .expect("reconcile sessions");

            session_service::create_task(
                &state.session_id,
                "refresh daemon cache",
                None,
                crate::session::types::TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("create task");

            let refreshed_projects =
                crate::daemon::index::discover_projects().expect("rediscover projects");
            let refreshed_sessions =
                crate::daemon::index::discover_sessions_for(&refreshed_projects, true)
                    .expect("rediscover sessions");
            let resolved = refreshed_sessions
                .into_iter()
                .find(|resolved| resolved.state.session_id == state.session_id)
                .expect("resolved session");

            assert!(
                session_import_required(&db, &resolved).expect("version check"),
                "newer file state should still prepare for import"
            );
        });
    }

    #[derive(Clone, Copy)]
    enum IdleSignalScriptBehavior {
        AckOnWake,
        IgnoreWake,
    }

    fn write_idle_signal_script(
        project: &Path,
        signal_dir: &Path,
        runtime_session_id: &str,
        orchestration_session_id: &str,
        behavior: IdleSignalScriptBehavior,
    ) -> std::path::PathBuf {
        let script_path = project.join(match behavior {
            IdleSignalScriptBehavior::AckOnWake => "idle-signal-ack.sh",
            IdleSignalScriptBehavior::IgnoreWake => "idle-signal-ignore.sh",
        });
        let wake_behavior = match behavior {
            IdleSignalScriptBehavior::AckOnWake => format!(
                r#"attempt=0
while [ "$attempt" -lt 20 ]; do
  for signal_file in "{signal_dir}/pending"/*.json; do
    if [ -e "$signal_file" ]; then
      signal_id=$(basename "$signal_file" .json)
      ack_dir="{signal_dir}/acknowledged"
      mkdir -p "$ack_dir"
      cat > "$ack_dir/$signal_id.ack.json" <<EOF
{{"signal_id":"$signal_id","acknowledged_at":"2026-04-13T00:00:00Z","result":"accepted","agent":"{runtime_session_id}","session_id":"{orchestration_session_id}"}}
EOF
      mv "$signal_file" "$ack_dir/$signal_id.json"
      exit 0
    fi
  done
  attempt=$((attempt + 1))
  sleep 0.1
done
exit 1
"#,
                signal_dir = signal_dir.display(),
                runtime_session_id = runtime_session_id,
                orchestration_session_id = orchestration_session_id
            ),
            IdleSignalScriptBehavior::IgnoreWake => "sleep 2\nexit 0\n".to_string(),
        };
        let script = format!(
            r#"#!/bin/sh
while IFS= read -r _line; do
  {wake_behavior}
done
"#
        );
        fs::write(&script_path, script).expect("write idle signal script");
        let mut permissions = fs::metadata(&script_path)
            .expect("script metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script_path, permissions).expect("set script executable");
        script_path
    }

    #[test]
    fn diagnostics_report_includes_workspace_and_recent_events() {
        let tmp = tempdir().expect("tempdir");
        let home = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HOME", Some(home.path().to_str().expect("utf8 path"))),
            ],
            || {
                let manifest = DaemonManifest {
                    version: "14.5.0".into(),
                    pid: 42,
                    endpoint: "http://127.0.0.1:9999".into(),
                    started_at: "2026-03-28T12:00:00Z".into(),
                    token_path: state::auth_token_path().display().to_string(),
                    sandboxed: false,
                    host_bridge: super::state::HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                state::write_manifest(&manifest).expect("manifest");
                state::append_event("info", "daemon booted").expect("append event");

                let report = diagnostics_report(None).expect("diagnostics");

                assert_eq!(
                    report.manifest.expect("manifest").endpoint,
                    manifest.endpoint
                );
                assert_eq!(report.health.expect("health").session_count, 0);
                assert!(report.workspace.events_path.ends_with("events.jsonl"));
                assert_eq!(report.recent_events.len(), 1);
            },
        );
    }

    #[test]
    fn create_task_uses_suggested_fix_from_request() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon task request",
                "",
                project,
                Some("claude"),
                Some("daemon-task"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");

            append_project_ledger_entry(project);
            let detail = create_task(
                &state.session_id,
                &TaskCreateRequest {
                    actor: leader_id,
                    title: "Patch the watch mapper".into(),
                    context: Some("watch loop uses the wrong session key".into()),
                    severity: crate::session::types::TaskSeverity::High,
                    suggested_fix: Some("resolve runtime-session ids through daemon index".into()),
                },
                None,
            )
            .expect("create task");

            assert_eq!(detail.tasks.len(), 1);
            assert_eq!(
                detail.tasks[0].suggested_fix.as_deref(),
                Some("resolve runtime-session ids through daemon index")
            );
        });
    }

    #[test]
    fn sessions_updated_event_includes_projects_and_sessions() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon stream index payload",
                "",
                project,
                Some("claude"),
                Some("daemon-stream-index"),
            )
            .expect("start session");

            let event = sessions_updated_event(None).expect("sessions updated event");
            let payload: SessionsUpdatedPayload =
                serde_json::from_value(event.payload).expect("deserialize payload");

            assert_eq!(event.event, "sessions_updated");
            assert!(event.session_id.is_none());
            assert_eq!(payload.projects.len(), 1);
            assert_eq!(payload.sessions.len(), 1);
            assert_eq!(payload.sessions[0].session_id, state.session_id);
        });
    }

    #[test]
    fn session_detail_marks_dead_leader_leaderless_and_hides_dead_agents() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon leaderless detail",
                "",
                project,
                Some("claude"),
                Some("daemon-leaderless-detail"),
            )
            .expect("start session");

            temp_env::with_var(
                "CODEX_SESSION_ID",
                Some("leaderless-worker-session"),
                || {
                    session_service::join_session(
                        &state.session_id,
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                        None,
                    )
                    .expect("join worker");
                },
            );

            let status =
                session_service::session_status(&state.session_id, project).expect("status");
            let leader = status
                .leader_id
                .as_ref()
                .and_then(|agent_id| status.agents.get(agent_id))
                .expect("leader agent");
            let worker = status
                .agents
                .values()
                .find(|agent| agent.runtime == "codex")
                .expect("worker agent");

            let leader_log = write_agent_log_file(
                project,
                "claude",
                leader
                    .agent_session_id
                    .as_deref()
                    .expect("leader session id"),
            );
            set_log_mtime_seconds_ago(&leader_log, 600);
            write_agent_log_file(
                project,
                "codex",
                worker
                    .agent_session_id
                    .as_deref()
                    .expect("worker session id"),
            );

            let db = setup_db_with_project(project);
            let project_id = index::discovered_project_for_checkout(project).project_id;
            db.sync_session(&project_id, &state).expect("sync");
            let detail = session_detail(&state.session_id, Some(&db)).expect("session detail");
            assert!(
                detail.session.leader_id.is_none(),
                "dead leader should clear leader_id"
            );
            assert_eq!(detail.session.metrics.agent_count, 1);
            assert_eq!(detail.session.metrics.active_agent_count, 1);
            assert_eq!(
                detail.agents.len(),
                1,
                "only the live worker should remain visible"
            );
            assert_eq!(detail.agents[0].runtime, "codex");
        });
    }

    #[test]
    fn list_sessions_db_marks_dead_leader_leaderless_and_excludes_dead_members() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon leaderless summaries",
                "",
                project,
                Some("claude"),
                Some("daemon-leaderless-summaries"),
            )
            .expect("start session");

            temp_env::with_var(
                "CODEX_SESSION_ID",
                Some("leaderless-db-worker-session"),
                || {
                    session_service::join_session(
                        &state.session_id,
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                        None,
                    )
                    .expect("join worker");
                },
            );

            let status =
                session_service::session_status(&state.session_id, project).expect("status");
            let leader = status
                .leader_id
                .as_ref()
                .and_then(|agent_id| status.agents.get(agent_id))
                .expect("leader agent");
            let worker = status
                .agents
                .values()
                .find(|agent| agent.runtime == "codex")
                .expect("worker agent");

            let leader_log = write_agent_log_file(
                project,
                "claude",
                leader
                    .agent_session_id
                    .as_deref()
                    .expect("leader session id"),
            );
            set_log_mtime_seconds_ago(&leader_log, 600);
            write_agent_log_file(
                project,
                "codex",
                worker
                    .agent_session_id
                    .as_deref()
                    .expect("worker session id"),
            );

            let db = setup_db_with_session(project, &state.session_id);

            let sessions = list_sessions(true, Some(&db)).expect("session summaries");
            let summary = sessions
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("summary");
            assert!(
                summary.leader_id.is_none(),
                "dead leader should clear leader_id"
            );
            assert_eq!(summary.metrics.agent_count, 1);
            assert_eq!(summary.metrics.active_agent_count, 1);

            let synced_state = db
                .load_session_state(&state.session_id)
                .expect("load state")
                .expect("session present");
            assert!(
                synced_state.leader_id.is_none(),
                "db state should persist leaderless session"
            );
            let leader_id = state.leader_id.as_ref().expect("leader id");
            let dead_leader = synced_state.agents.get(leader_id).expect("leader agent");
            assert_eq!(dead_leader.status, AgentStatus::Disconnected);
        });
    }

    #[test]
    fn list_sessions_reads_cached_liveness_state_within_ttl() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon cached liveness summaries",
                "",
                project,
                Some("claude"),
                Some("daemon-cached-liveness-summaries"),
            )
            .expect("start session");

            temp_env::with_var("CODEX_SESSION_ID", Some("cached-db-worker-session"), || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker");
            });

            let status =
                session_service::session_status(&state.session_id, project).expect("status");
            let leader = status
                .leader_id
                .as_ref()
                .and_then(|agent_id| status.agents.get(agent_id))
                .expect("leader agent");
            let worker = status
                .agents
                .values()
                .find(|agent| agent.runtime == "codex")
                .expect("worker agent");

            let leader_log = write_agent_log_file(
                project,
                "claude",
                leader
                    .agent_session_id
                    .as_deref()
                    .expect("leader session id"),
            );
            write_agent_log_file(
                project,
                "codex",
                worker
                    .agent_session_id
                    .as_deref()
                    .expect("worker session id"),
            );

            let db = setup_db_with_session(project, &state.session_id);
            clear_session_liveness_refresh_cache_entry(&state.session_id);

            let first_summary = list_sessions(true, Some(&db))
                .expect("first session summaries")
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("first summary");
            assert_eq!(first_summary.leader_id, state.leader_id);
            assert_eq!(first_summary.metrics.agent_count, 2);
            assert_eq!(first_summary.metrics.active_agent_count, 2);

            set_log_mtime_seconds_ago(&leader_log, 600);

            let second_summary = list_sessions(true, Some(&db))
                .expect("second session summaries")
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("second summary");
            assert_eq!(
                second_summary.leader_id, state.leader_id,
                "cached liveness should defer leader cleanup within the TTL"
            );
            assert_eq!(second_summary.metrics.agent_count, 2);
            assert_eq!(second_summary.metrics.active_agent_count, 2);
        });
    }

    #[test]
    fn list_sessions_skips_liveness_disk_probe_when_db_session_has_no_live_agents() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon dead-session summaries",
                "",
                project,
                Some("claude"),
                Some("daemon-dead-session-summaries"),
            )
            .expect("start session");

            temp_env::with_var("CODEX_SESSION_ID", Some("dead-db-worker-session"), || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker");
            });

            let status =
                session_service::session_status(&state.session_id, project).expect("status");
            let leader = status
                .leader_id
                .as_ref()
                .and_then(|agent_id| status.agents.get(agent_id))
                .expect("leader agent");
            let worker = status
                .agents
                .values()
                .find(|agent| agent.runtime == "codex")
                .expect("worker agent");

            let leader_log = write_agent_log_file(
                project,
                "claude",
                leader
                    .agent_session_id
                    .as_deref()
                    .expect("leader session id"),
            );
            let worker_log = write_agent_log_file(
                project,
                "codex",
                worker
                    .agent_session_id
                    .as_deref()
                    .expect("worker session id"),
            );
            set_log_mtime_seconds_ago(&leader_log, 600);
            set_log_mtime_seconds_ago(&worker_log, 600);

            let liveness = session_service::sync_agent_liveness(&state.session_id, project)
                .expect("sync dead liveness");
            assert_eq!(liveness.disconnected.len(), 2);

            let db = setup_db_with_session(project, &state.session_id);
            clear_session_liveness_refresh_cache_entry(&state.session_id);

            let state_path = crate::workspace::project_context_dir(project)
                .join("orchestration")
                .join("sessions")
                .join(&state.session_id)
                .join("state.json");
            fs::write(&state_path, "{not-valid-json").expect("corrupt state");

            let summary = list_sessions(true, Some(&db))
                .expect("session summaries should stay on the db fast path")
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("summary");
            assert!(summary.leader_id.is_none());
            assert_eq!(summary.metrics.agent_count, 0);
            assert_eq!(summary.metrics.active_agent_count, 0);
        });
    }

    #[test]
    fn stale_session_ids_for_liveness_refresh_skips_recent_sessions() {
        let now = Instant::now();
        let mut cache = BTreeMap::new();

        let first = stale_session_ids_for_liveness_refresh(
            &mut cache,
            BTreeSet::from([String::from("sess-1")]),
            now,
        );
        assert_eq!(first, vec![String::from("sess-1")]);

        let second = stale_session_ids_for_liveness_refresh(
            &mut cache,
            BTreeSet::from([String::from("sess-1")]),
            now + Duration::from_secs(1),
        );
        assert!(second.is_empty(), "recent sessions should be skipped");

        let third = stale_session_ids_for_liveness_refresh(
            &mut cache,
            BTreeSet::from([String::from("sess-1")]),
            now + SESSION_LIVENESS_REFRESH_TTL + Duration::from_secs(1),
        );
        assert_eq!(third, vec![String::from("sess-1")]);
    }

    #[test]
    fn global_stream_initial_events_include_current_session_index() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon stream initial index payload",
                "",
                project,
                Some("claude"),
                Some("daemon-stream-initial-index"),
            )
            .expect("start session");

            let events = global_stream_initial_events(None);
            let snapshot = events
                .iter()
                .find(|event| event.event == "sessions_updated")
                .expect("sessions_updated event");
            let payload: SessionsUpdatedPayload =
                serde_json::from_value(snapshot.payload.clone()).expect("deserialize payload");

            assert_eq!(events[0].event, "ready");
            assert!(events[0].session_id.is_none());
            assert!(
                payload
                    .sessions
                    .iter()
                    .any(|session| { session.session_id == state.session_id })
            );
        });
    }

    #[test]
    fn session_stream_initial_events_include_current_session_snapshot() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon stream initial session payload",
                "",
                project,
                Some("claude"),
                Some("daemon-stream-initial-session"),
            )
            .expect("start session");

            let events = session_stream_initial_events(&state.session_id, None);
            let update = events
                .iter()
                .find(|event| event.event == "session_updated")
                .expect("session_updated event");
            let payload: SessionUpdatedPayload =
                serde_json::from_value(update.payload.clone()).expect("deserialize payload");

            assert_eq!(events[0].event, "ready");
            assert_eq!(
                events[0].session_id.as_deref(),
                Some(state.session_id.as_str())
            );
            assert_eq!(
                update.session_id.as_deref(),
                Some(state.session_id.as_str())
            );
            assert_eq!(payload.detail.session.session_id, state.session_id);
            assert!(payload.extensions_pending);
        });
    }

    #[test]
    fn session_updated_event_includes_detail_without_timeline() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon stream session payload",
                "",
                project,
                Some("claude"),
                Some("daemon-stream-session"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");
            append_project_ledger_entry(project);
            session_service::create_task(
                &state.session_id,
                "materialize timeline",
                None,
                crate::session::types::TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("create task");

            let event =
                session_updated_event(&state.session_id, None).expect("session updated event");
            let payload: SessionUpdatedPayload =
                serde_json::from_value(event.payload).expect("deserialize payload");

            assert_eq!(event.event, "session_updated");
            assert_eq!(event.session_id.as_deref(), Some(state.session_id.as_str()));
            assert_eq!(payload.detail.session.session_id, state.session_id);
            assert!(payload.timeline.is_none());
        });
    }

    #[test]
    fn change_role_records_reason_from_request() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon role request",
                "",
                project,
                Some("claude"),
                Some("daemon-role"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");
            let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("role-worker"))], || {
                session_service::join_session(
                    "daemon-role",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            });
            let worker_id = joined
                .agents
                .keys()
                .find(|agent_id| agent_id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            append_project_ledger_entry(project);

            let _ = change_role(
                "daemon-role",
                &worker_id,
                &RoleChangeRequest {
                    actor: leader_id,
                    role: SessionRole::Reviewer,
                    reason: Some("route triage through a reviewer".into()),
                },
                None,
            )
            .expect("change role");

            let entries = session_service::session_status("daemon-role", project)
                .expect("status")
                .tasks;
            assert!(entries.is_empty());
            let log_entries =
                crate::session::storage::load_log_entries(project, "daemon-role").expect("log");
            assert!(log_entries.into_iter().any(|entry| {
                entry.reason.as_deref() == Some("route triage through a reviewer")
                    && matches!(
                        entry.transition,
                        crate::session::types::SessionTransition::RoleChanged { ref agent_id, .. }
                            if agent_id == &worker_id
                    )
            }));
        });
    }

    #[test]
    fn send_signal_returns_detail_with_pending_signal() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon signal request",
                "",
                project,
                Some("claude"),
                Some("daemon-signal"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("daemon-signal-worker"))], || {
                    session_service::join_session(
                        "daemon-signal",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                        None,
                    )
                    .expect("join worker")
                });
            let worker_id = joined
                .agents
                .keys()
                .find(|agent_id| agent_id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            let detail = send_signal(
                "daemon-signal",
                &SignalSendRequest {
                    actor: leader_id,
                    agent_id: worker_id.clone(),
                    command: "inject_context".into(),
                    message: "Investigate the stuck signal lane".into(),
                    action_hint: Some("task:signal".into()),
                },
                None,
                None,
            )
            .expect("send signal");

            assert_eq!(detail.session.session_id, "daemon-signal");
            assert_eq!(detail.signals.len(), 1);
            assert_eq!(detail.signals[0].agent_id, worker_id);
            assert_eq!(detail.signals[0].status, SessionSignalStatus::Pending);
            assert_eq!(detail.signals[0].signal.command, "inject_context");
            assert_eq!(
                detail.signals[0].signal.payload.message,
                "Investigate the stuck signal lane"
            );
            assert_eq!(
                detail.signals[0].signal.payload.action_hint.as_deref(),
                Some("task:signal")
            );
        });
    }

    #[test]
    fn send_signal_db_direct_actively_delivers_to_idle_tui_agent() {
        with_temp_project(|project| {
            use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

            let db = Arc::new(Mutex::new(setup_db_with_project(project)));
            let db_slot = Arc::new(OnceLock::new());
            db_slot.set(Arc::clone(&db)).expect("db slot");
            let (sender, _) = broadcast::channel(8);
            let manager = AgentTuiManagerHandle::new(sender, db_slot, false);

            {
                let db_guard = db.lock().expect("db lock");
                start_session_direct(
                    &SessionStartRequest {
                        title: "daemon active signal".into(),
                        context: "wake idle tui".into(),
                        runtime: "claude".into(),
                        session_id: Some("daemon-active-signal".into()),
                        project_dir: project.to_string_lossy().into(),
                    },
                    Some(&db_guard),
                )
                .expect("start session");
            }

            let worker_session_id = "daemon-active-signal-worker";
            let signal_dir = runtime::runtime_for_name("codex")
                .expect("codex runtime")
                .signal_dir(project, worker_session_id);
            let script_path = write_idle_signal_script(
                project,
                &signal_dir,
                worker_session_id,
                "daemon-active-signal",
                IdleSignalScriptBehavior::AckOnWake,
            );

            let snapshot = manager
                .start(
                    "daemon-active-signal",
                    &AgentTuiStartRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        capabilities: vec![],
                        name: Some("idle worker".into()),
                        prompt: None,
                        project_dir: Some(project.to_string_lossy().into()),
                        argv: vec!["sh".into(), script_path.to_string_lossy().into_owned()],
                        rows: 5,
                        cols: 40,
                        persona: None,
                    },
                )
                .expect("start agent tui");
            // Simulate the SessionStart hook callback.
            manager
                .signal_ready(&snapshot.tui_id)
                .expect("signal ready");

            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some(worker_session_id))], || {
                    let db_guard = db.lock().expect("db lock");
                    join_session_direct(
                        "daemon-active-signal",
                        &SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            capabilities: vec![
                                "agent-tui".into(),
                                format!("agent-tui:{}", snapshot.tui_id),
                            ],
                            name: Some("idle worker".into()),
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        Some(&db_guard),
                    )
                    .expect("join worker")
                });
            let worker_id = joined
                .agents
                .values()
                .find(|agent| agent.role == SessionRole::Worker)
                .expect("worker agent")
                .agent_id
                .clone();

            let detail = {
                let db_guard = db.lock().expect("db lock");
                send_signal(
                    "daemon-active-signal",
                    &SignalSendRequest {
                        actor: joined.leader_id.clone().expect("leader id"),
                        agent_id: worker_id.clone(),
                        command: "inject_context".into(),
                        message: "deliver immediately".into(),
                        action_hint: Some("task:active".into()),
                    },
                    Some(&db_guard),
                    Some(&manager),
                )
                .expect("send signal")
            };

            let signal = detail
                .signals
                .iter()
                .find(|signal| {
                    signal.agent_id == worker_id
                        && signal.signal.payload.message == "deliver immediately"
                })
                .expect("delivered signal");
            assert_eq!(signal.status, SessionSignalStatus::Delivered);
            assert_eq!(
                signal.acknowledgment.as_ref().map(|ack| ack.result),
                Some(AckResult::Accepted)
            );
        });
    }

    #[test]
    fn send_signal_db_direct_warns_when_idle_tui_ack_times_out() {
        with_temp_project(|project| {
            use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

            let db = Arc::new(Mutex::new(setup_db_with_project(project)));
            let db_slot = Arc::new(OnceLock::new());
            db_slot.set(Arc::clone(&db)).expect("db slot");
            let (sender, _) = broadcast::channel(8);
            let manager = AgentTuiManagerHandle::new(sender, db_slot, false);

            {
                let db_guard = db.lock().expect("db lock");
                start_session_direct(
                    &SessionStartRequest {
                        title: "daemon timed signal".into(),
                        context: "warn when idle tui ignores wake".into(),
                        runtime: "claude".into(),
                        session_id: Some("daemon-timed-signal".into()),
                        project_dir: project.to_string_lossy().into(),
                    },
                    Some(&db_guard),
                )
                .expect("start session");
            }

            let worker_session_id = "daemon-timed-signal-worker";
            let signal_dir = runtime::runtime_for_name("codex")
                .expect("codex runtime")
                .signal_dir(project, worker_session_id);
            let script_path = write_idle_signal_script(
                project,
                &signal_dir,
                worker_session_id,
                "daemon-timed-signal",
                IdleSignalScriptBehavior::IgnoreWake,
            );

            let snapshot = manager
                .start(
                    "daemon-timed-signal",
                    &AgentTuiStartRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        capabilities: vec![],
                        name: Some("sleepy worker".into()),
                        prompt: None,
                        project_dir: Some(project.to_string_lossy().into()),
                        argv: vec!["sh".into(), script_path.to_string_lossy().into_owned()],
                        rows: 5,
                        cols: 40,
                        persona: None,
                    },
                )
                .expect("start agent tui");
            manager
                .signal_ready(&snapshot.tui_id)
                .expect("signal ready");

            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some(worker_session_id))], || {
                    let db_guard = db.lock().expect("db lock");
                    join_session_direct(
                        "daemon-timed-signal",
                        &SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            capabilities: vec![
                                "agent-tui".into(),
                                format!("agent-tui:{}", snapshot.tui_id),
                            ],
                            name: Some("sleepy worker".into()),
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        Some(&db_guard),
                    )
                    .expect("join worker")
                });
            let worker_id = joined
                .agents
                .values()
                .find(|agent| agent.role == SessionRole::Worker)
                .expect("worker agent")
                .agent_id
                .clone();

            let detail = {
                let db_guard = db.lock().expect("db lock");
                send_signal(
                    "daemon-timed-signal",
                    &SignalSendRequest {
                        actor: joined.leader_id.clone().expect("leader id"),
                        agent_id: worker_id.clone(),
                        command: "inject_context".into(),
                        message: "stay pending".into(),
                        action_hint: Some("task:warn".into()),
                    },
                    Some(&db_guard),
                    Some(&manager),
                )
                .expect("send signal")
            };

            let signal = detail
                .signals
                .iter()
                .find(|signal| {
                    signal.agent_id == worker_id && signal.signal.payload.message == "stay pending"
                })
                .expect("pending signal");
            assert_eq!(signal.status, SessionSignalStatus::Pending);

            let events = state::read_recent_events(1).expect("read daemon events");
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].level, "warn");
            assert!(
                events[0].message.contains("daemon-timed-signal")
                    && events[0].message.contains(&worker_id),
                "warning should mention session and agent: {}",
                events[0].message
            );
        });
    }

    #[test]
    fn cancel_signal_flips_status_to_rejected_and_logs_entry() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon cancel request",
                "",
                project,
                Some("claude"),
                Some("daemon-cancel"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("daemon-cancel-worker"))], || {
                    session_service::join_session(
                        "daemon-cancel",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                        None,
                    )
                    .expect("join worker")
                });
            let worker_id = joined
                .agents
                .keys()
                .find(|agent_id| agent_id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            let sent = send_signal(
                "daemon-cancel",
                &SignalSendRequest {
                    actor: leader_id.clone(),
                    agent_id: worker_id.clone(),
                    command: "inject_context".into(),
                    message: "Investigate the stuck signal lane".into(),
                    action_hint: Some("task:signal".into()),
                },
                None,
                None,
            )
            .expect("send signal");
            let signal_id = sent.signals[0].signal.signal_id.clone();

            let detail = cancel_signal(
                "daemon-cancel",
                &super::super::protocol::SignalCancelRequest {
                    actor: leader_id,
                    agent_id: worker_id.clone(),
                    signal_id: signal_id.clone(),
                },
                None,
            )
            .expect("cancel signal");

            assert_eq!(detail.signals.len(), 1);
            assert_eq!(detail.signals[0].status, SessionSignalStatus::Rejected);
            assert_eq!(detail.signals[0].signal.signal_id, signal_id);
            assert_eq!(
                detail.signals[0]
                    .acknowledgment
                    .as_ref()
                    .map(|ack| ack.result),
                Some(crate::agents::runtime::signal::AckResult::Rejected)
            );

            let log_entries =
                crate::session::storage::load_log_entries(project, "daemon-cancel").expect("log");
            assert!(log_entries.into_iter().any(|entry| matches!(
                entry.transition,
                crate::session::types::SessionTransition::SignalAcknowledged {
                    signal_id: ref id,
                    result: crate::agents::runtime::signal::AckResult::Rejected,
                    ..
                } if id == &signal_id
            )));
        });
    }

    #[test]
    fn cancel_signal_errors_when_signal_not_pending() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "daemon cancel missing",
                "",
                project,
                Some("claude"),
                Some("daemon-cancel-missing"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");
            let joined = temp_env::with_vars(
                [("CODEX_SESSION_ID", Some("daemon-cancel-missing-worker"))],
                || {
                    session_service::join_session(
                        "daemon-cancel-missing",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                        None,
                    )
                    .expect("join worker")
                },
            );
            let worker_id = joined
                .agents
                .keys()
                .find(|agent_id| agent_id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            let result = cancel_signal(
                "daemon-cancel-missing",
                &super::super::protocol::SignalCancelRequest {
                    actor: leader_id,
                    agent_id: worker_id,
                    signal_id: "nonexistent-signal".into(),
                },
                None,
            );

            assert!(result.is_err(), "cancel should fail when signal missing");
        });
    }

    /// Build an in-memory DB with a project and session loaded from files.
    fn setup_db_with_session(project: &Path, session_id: &str) -> crate::daemon::db::DaemonDb {
        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open in-memory db");
        let projects = index::discover_projects().expect("discover projects");
        for p in &projects {
            db.sync_project(p).expect("sync project");
        }
        let resolved = index::resolve_session(session_id).expect("resolve session");
        db.sync_session(&resolved.project.project_id, &resolved.state)
            .expect("sync session");
        append_project_ledger_entry(project);
        db
    }

    /// Build an in-memory DB with a project and session loaded only into
    /// SQLite (no files for that session). The session only exists in the DB.
    fn setup_db_only_session(
        project: &Path,
    ) -> (
        crate::daemon::db::DaemonDb,
        crate::session::types::SessionState,
    ) {
        use crate::session::service::build_new_session;

        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open in-memory db");

        let project_record = index::discovered_project_for_checkout(project);
        db.sync_project(&project_record).expect("sync project");

        let state = build_new_session(
            "db-only test",
            "",
            "db-only-sess",
            "claude",
            Some("test-session"),
            &utc_now(),
        );
        db.sync_session(&project_record.project_id, &state)
            .expect("sync session");
        (db, state)
    }

    fn join_db_codex_worker(
        db: &crate::daemon::db::DaemonDb,
        state: &crate::session::types::SessionState,
        project: &Path,
        runtime_session_id: &str,
    ) -> String {
        use crate::daemon::protocol::SessionJoinRequest;

        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some(runtime_session_id))], || {
            join_session_direct(
                &state.session_id,
                &SessionJoinRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    capabilities: vec![],
                    name: None,
                    project_dir: project.to_string_lossy().into(),
                    persona: None,
                },
                Some(db),
            )
            .expect("join db worker")
        });
        joined
            .agents
            .keys()
            .find(|agent_id| agent_id.starts_with("codex-"))
            .expect("worker id")
            .clone()
    }

    #[test]
    fn create_task_db_direct_writes_to_sqlite() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.expect("leader id");

            let detail = create_task(
                &state.session_id,
                &TaskCreateRequest {
                    actor: leader_id,
                    title: "db-direct task".into(),
                    context: None,
                    severity: crate::session::types::TaskSeverity::Medium,
                    suggested_fix: None,
                },
                Some(&db),
            )
            .expect("create task via db");

            assert_eq!(detail.tasks.len(), 1);
            assert_eq!(detail.tasks[0].title, "db-direct task");

            let db_state = db
                .load_session_state(&state.session_id)
                .expect("load state")
                .expect("state present");
            assert_eq!(db_state.tasks.len(), 1);
        });
    }

    #[test]
    fn join_session_direct_rejects_leader_role() {
        with_temp_project(|project| {
            use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

            let db = setup_db_with_project(project);
            start_session_direct(
                &SessionStartRequest {
                    title: "leader join denied".into(),
                    context: "daemon joins cannot claim leader".into(),
                    runtime: "claude".into(),
                    session_id: Some("leader-join-denied".into()),
                    project_dir: project.to_string_lossy().into(),
                },
                Some(&db),
            )
            .expect("start session");

            let result =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("leader-join-worker"))], || {
                    join_session_direct(
                        "leader-join-denied",
                        &SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Leader,
                            capabilities: vec![],
                            name: Some("spoofed leader".into()),
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        Some(&db),
                    )
                });

            let error = result.expect_err("leader join should be rejected");
            assert_eq!(error.code(), "KSRCLI092");
            assert!(error.message().contains("leader"));
        });
    }

    #[test]
    fn end_session_db_direct_marks_inactive() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_id = join_db_codex_worker(&db, &state, project, "db-end-worker");

            let detail = end_session(
                &state.session_id,
                &SessionEndRequest { actor: leader_id },
                Some(&db),
            )
            .expect("end session via db");

            assert_eq!(detail.session.status, SessionStatus::Ended);
            assert_eq!(detail.session.metrics.active_agent_count, 0);
            assert!(detail.session.leader_id.is_none());
            assert!(
                detail.agents.is_empty(),
                "ended sessions should not expose dead agents"
            );
            assert_eq!(detail.signals.len(), 2);
            assert!(
                detail
                    .signals
                    .iter()
                    .any(|signal| signal.agent_id == worker_id)
            );
            assert!(
                detail
                    .signals
                    .iter()
                    .all(|signal| signal.signal.command == "abort")
            );

            let db_state = db
                .load_session_state(&state.session_id)
                .expect("load state")
                .expect("state present");
            assert_eq!(db_state.status, SessionStatus::Ended);
            assert_eq!(
                db.load_signals(&state.session_id).expect("signals").len(),
                2
            );
        });
    }

    #[test]
    fn session_timeline_window_known_revision_reloads_when_visible_rows_change_without_count_change()
     {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let request = TimelineWindowRequest {
                scope: Some("summary".into()),
                limit: Some(20),
                ..TimelineWindowRequest::default()
            };

            let first = crate::agents::runtime::event::ConversationEvent {
                timestamp: Some("2026-04-14T10:00:00Z".into()),
                sequence: 1,
                kind: crate::agents::runtime::event::ConversationEventKind::Error {
                    code: None,
                    message: "first failure".into(),
                    recoverable: true,
                },
                agent: "claude-leader".into(),
                session_id: state.session_id.clone(),
            };
            db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &[first])
                .expect("sync first event");

            let initial = session_timeline_window(&state.session_id, &request, Some(&db))
                .expect("load initial window");
            assert_eq!(initial.total_count, 1);
            assert!(!initial.unchanged);
            let revision = initial.revision;

            let replacement = crate::agents::runtime::event::ConversationEvent {
                timestamp: Some("2026-04-14T10:00:00Z".into()),
                sequence: 1,
                kind: crate::agents::runtime::event::ConversationEventKind::Error {
                    code: None,
                    message: "replacement failure".into(),
                    recoverable: true,
                },
                agent: "claude-leader".into(),
                session_id: state.session_id.clone(),
            };
            db.sync_conversation_events(
                &state.session_id,
                "claude-leader",
                "claude",
                &[replacement],
            )
            .expect("sync replacement event");

            let refreshed = session_timeline_window(
                &state.session_id,
                &TimelineWindowRequest {
                    known_revision: Some(revision),
                    ..request.clone()
                },
                Some(&db),
            )
            .expect("load refreshed window");

            assert!(
                !refreshed.unchanged,
                "same-count timeline edits must not short-circuit as unchanged"
            );
            let entries = refreshed.entries.expect("entries");
            assert_eq!(entries.len(), 1);
            assert_eq!(
                entries[0].summary,
                "claude-leader error: replacement failure"
            );
        });
    }

    #[test]
    fn remove_agent_db_direct_sends_abort_signal() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_id = join_db_codex_worker(&db, &state, project, "db-remove-worker");

            let detail = remove_agent(
                &state.session_id,
                &worker_id,
                &AgentRemoveRequest { actor: leader_id },
                Some(&db),
            )
            .expect("remove via db");

            assert!(
                detail
                    .agents
                    .iter()
                    .all(|agent| agent.agent_id != worker_id),
                "removed agents should disappear from session detail"
            );
            assert_eq!(detail.signals.len(), 1);
            assert_eq!(detail.signals[0].agent_id, worker_id);
            assert_eq!(detail.signals[0].signal.command, "abort");
            assert_eq!(detail.signals[0].status, SessionSignalStatus::Pending);
        });
    }

    #[test]
    fn send_signal_db_direct_refreshes_non_empty_signal_index() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.clone().expect("leader id");

            let first = send_signal(
                &state.session_id,
                &SignalSendRequest {
                    actor: leader_id.clone(),
                    agent_id: leader_id.clone(),
                    command: "inject_context".into(),
                    message: "first signal".into(),
                    action_hint: None,
                },
                Some(&db),
                None,
            )
            .expect("first signal");
            assert_eq!(first.signals.len(), 1);

            let second = send_signal(
                &state.session_id,
                &SignalSendRequest {
                    actor: leader_id.clone(),
                    agent_id: leader_id,
                    command: "inject_context".into(),
                    message: "second signal".into(),
                    action_hint: None,
                },
                Some(&db),
                None,
            )
            .expect("second signal");

            assert_eq!(second.signals.len(), 2);
            let messages: Vec<_> = second
                .signals
                .iter()
                .map(|signal| signal.signal.payload.message.as_str())
                .collect();
            assert!(messages.contains(&"first signal"));
            assert!(messages.contains(&"second signal"));
        });
    }

    #[test]
    fn task_start_ack_db_direct_starts_work_only_after_delivery() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_session_id = "db-task-delivery-worker";
            let worker_id = join_db_codex_worker(&db, &state, project, worker_session_id);

            let created = create_task(
                &state.session_id,
                &TaskCreateRequest {
                    actor: leader_id.clone(),
                    title: "Start after delivery".into(),
                    context: None,
                    severity: crate::session::types::TaskSeverity::Medium,
                    suggested_fix: None,
                },
                Some(&db),
            )
            .expect("create task");
            let task_id = created.tasks[0].task_id.clone();

            let dropped = drop_task(
                &state.session_id,
                &task_id,
                &TaskDropRequest {
                    actor: leader_id,
                    target: super::super::protocol::TaskDropTarget::Agent {
                        agent_id: worker_id.clone(),
                    },
                    queue_policy: crate::session::types::TaskQueuePolicy::Locked,
                },
                Some(&db),
            )
            .expect("drop task");

            let pending_task = dropped
                .tasks
                .iter()
                .find(|task| task.task_id == task_id)
                .expect("pending task");
            assert_eq!(pending_task.status, crate::session::types::TaskStatus::Open);
            assert_eq!(
                pending_task.assigned_to.as_deref(),
                Some(worker_id.as_str())
            );
            assert!(pending_task.queued_at.is_none());
            let worker = dropped
                .agents
                .iter()
                .find(|agent| agent.agent_id == worker_id)
                .expect("worker");
            assert!(worker.current_task_id.is_none());
            assert!(
                !db.load_session_log(&state.session_id)
                    .expect("session log")
                    .into_iter()
                    .any(|entry| matches!(
                        entry.transition,
                        SessionTransition::TaskAssigned { ref task_id, ref agent_id }
                            if task_id == &pending_task.task_id && agent_id == &worker_id
                    ))
            );

            let signal = dropped
                .signals
                .iter()
                .find(|signal| signal.agent_id == worker_id)
                .expect("task signal");
            let signal_id = signal.signal.signal_id.clone();
            let runtime = runtime::runtime_for_name("codex").expect("codex runtime");
            let signal_dir = runtime.signal_dir(project, worker_session_id);
            runtime::signal::acknowledge_signal(
                &signal_dir,
                &SignalAck {
                    signal_id: signal_id.clone(),
                    acknowledged_at: utc_now(),
                    result: AckResult::Accepted,
                    agent: worker_session_id.to_string(),
                    session_id: state.session_id.clone(),
                    details: None,
                },
            )
            .expect("write signal ack");

            record_signal_ack_direct(
                &state.session_id,
                &super::super::protocol::SignalAckRequest {
                    agent_id: worker_id.clone(),
                    signal_id,
                    result: AckResult::Accepted,
                    project_dir: project.to_string_lossy().into_owned(),
                },
                Some(&db),
            )
            .expect("record signal ack");

            let detail = session_detail(&state.session_id, Some(&db)).expect("session detail");
            let active_task = detail
                .tasks
                .iter()
                .find(|task| task.task_id == task_id)
                .expect("active task");
            assert_eq!(
                active_task.status,
                crate::session::types::TaskStatus::InProgress
            );
            let worker = detail
                .agents
                .iter()
                .find(|agent| agent.agent_id == worker_id)
                .expect("worker");
            assert_eq!(worker.current_task_id.as_deref(), Some(task_id.as_str()));
            assert!(
                detail
                    .signals
                    .iter()
                    .any(|signal| signal.status == SessionSignalStatus::Delivered)
            );
            assert!(
                db.load_session_log(&state.session_id)
                    .expect("session log")
                    .into_iter()
                    .any(|entry| matches!(
                        entry.transition,
                        SessionTransition::TaskAssigned { ref task_id, ref agent_id }
                            if task_id == &active_task.task_id && agent_id == &worker_id
                    ))
            );
        });
    }

    #[test]
    fn session_detail_core_db_direct_reopens_expired_pending_delivery() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.clone().expect("leader id");
            let worker_session_id = "db-task-expired-worker";
            let worker_id = join_db_codex_worker(&db, &state, project, worker_session_id);

            let created = create_task(
                &state.session_id,
                &TaskCreateRequest {
                    actor: leader_id.clone(),
                    title: "Expire before delivery".into(),
                    context: None,
                    severity: crate::session::types::TaskSeverity::Medium,
                    suggested_fix: None,
                },
                Some(&db),
            )
            .expect("create task");
            let task_id = created.tasks[0].task_id.clone();

            let dropped = drop_task(
                &state.session_id,
                &task_id,
                &TaskDropRequest {
                    actor: leader_id,
                    target: super::super::protocol::TaskDropTarget::Agent {
                        agent_id: worker_id.clone(),
                    },
                    queue_policy: crate::session::types::TaskQueuePolicy::Locked,
                },
                Some(&db),
            )
            .expect("drop task");

            let signal = dropped
                .signals
                .iter()
                .find(|signal| signal.agent_id == worker_id)
                .expect("task signal")
                .signal
                .clone();
            let runtime = runtime::runtime_for_name("codex").expect("codex runtime");
            let signal_dir = runtime.signal_dir(project, worker_session_id);
            let expired_signal = crate::agents::runtime::signal::Signal {
                expires_at: "2000-01-01T00:00:00Z".into(),
                ..signal
            };
            fs::write(
                signal_dir
                    .join("pending")
                    .join(format!("{}.json", expired_signal.signal_id)),
                serde_json::to_string_pretty(&expired_signal).expect("serialize expired signal"),
            )
            .expect("rewrite expired signal");

            let core = session_detail_core(&state.session_id, Some(&db)).expect("core detail");
            let reopened_task = core
                .tasks
                .iter()
                .find(|task| task.task_id == task_id)
                .expect("reopened task");
            assert_eq!(
                reopened_task.status,
                crate::session::types::TaskStatus::Open
            );
            assert!(reopened_task.assigned_to.is_none());
            let worker = core
                .agents
                .iter()
                .find(|agent| agent.agent_id == worker_id)
                .expect("worker");
            assert!(worker.current_task_id.is_none());

            let extensions =
                session_extensions(&state.session_id, Some(&db)).expect("session extensions");
            let signal = extensions
                .signals
                .expect("signals")
                .into_iter()
                .find(|signal| signal.agent_id == worker_id)
                .expect("expired signal");
            assert_eq!(signal.status, SessionSignalStatus::Expired);
            assert_eq!(
                signal.acknowledgment.expect("ack").result,
                AckResult::Expired
            );
        });
    }

    #[test]
    fn observe_session_with_actor_creates_tasks() {
        install_test_observe_runtime(Duration::from_secs(60));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        with_temp_project(|project| {
            let state = session_service::start_session(
                "observe test",
                "",
                project,
                Some("claude"),
                Some("daemon-observe"),
            )
            .expect("start session");
            let leader_id = state.leader_id.clone().expect("leader id");

            temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join codex worker");
            });

            append_project_ledger_entry(project);
            write_agent_log(
                project,
                HookAgent::Codex,
                "worker-session",
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            let detail = runtime
                .block_on(async {
                    observe_session(
                        &state.session_id,
                        Some(&ObserveSessionRequest {
                            actor: Some(leader_id),
                        }),
                        None,
                    )
                })
                .expect("observe session");

            assert_eq!(detail.tasks.len(), 1);
            assert_eq!(
                detail.tasks[0].source,
                crate::session::types::TaskSource::Observe
            );
        });
    }

    #[test]
    fn observe_session_restarts_running_loop_when_actor_changes() {
        install_test_observe_runtime(Duration::from_secs(60));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        with_temp_project(|project| {
            let state = session_service::start_session(
                "observe restart test",
                "",
                project,
                Some("claude"),
                Some("daemon-observe"),
            )
            .expect("start session");
            let leader_id = state.leader_id.clone().expect("leader id");

            let joined_state =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                    session_service::join_session(
                        &state.session_id,
                        SessionRole::Observer,
                        "codex",
                        &[],
                        Some("observer"),
                        project,
                        None,
                    )
                })
                .expect("join observer");
            let observer_id = joined_state
                .agents
                .values()
                .find(|agent| agent.role == SessionRole::Observer)
                .map(|agent| agent.agent_id.clone())
                .expect("observer id");

            append_project_ledger_entry(project);
            write_agent_log(
                project,
                HookAgent::Codex,
                "observer-session",
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            runtime
                .block_on(async {
                    observe_session(
                        &state.session_id,
                        Some(&ObserveSessionRequest {
                            actor: Some(leader_id),
                        }),
                        None,
                    )
                })
                .expect("observe session with leader");
            runtime
                .block_on(async {
                    observe_session(
                        &state.session_id,
                        Some(&ObserveSessionRequest {
                            actor: Some(observer_id.clone()),
                        }),
                        None,
                    )
                })
                .expect("observe session with observer");

            let observe_runtime = OBSERVE_RUNTIME.get().expect("observe runtime");
            let running_sessions = observe_runtime
                .running_sessions
                .lock()
                .expect("running sessions lock");
            let registration = running_sessions
                .get(&state.session_id)
                .expect("running session registration");

            assert_eq!(
                registration.request.actor_id.as_deref(),
                Some(observer_id.as_str())
            );
            assert_eq!(registration.generation, 2);
        });
    }

    fn setup_db_with_project(project: &Path) -> crate::daemon::db::DaemonDb {
        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open db");
        let project_record = index::discovered_project_for_checkout(project);
        db.sync_project(&project_record).expect("sync project");
        db
    }

    #[test]
    fn start_session_db_direct_creates_in_sqlite() {
        with_temp_project(|project| {
            use crate::daemon::protocol::SessionStartRequest;

            let db = setup_db_with_project(project);

            let state = start_session_direct(
                &SessionStartRequest {
                    title: "db-direct start session".into(),
                    context: "db-direct start".into(),
                    runtime: "claude".into(),
                    session_id: Some("daemon-start-1".into()),
                    project_dir: project.to_string_lossy().into(),
                },
                Some(&db),
            )
            .expect("start session via db");

            assert_eq!(state.context, "db-direct start");
            assert!(state.leader_id.is_some());
            assert_eq!(state.agents.len(), 1);

            let db_state = db
                .load_session_state("daemon-start-1")
                .expect("load")
                .expect("present");
            assert_eq!(db_state.context, "db-direct start");
        });
    }

    #[test]
    fn start_session_db_direct_registers_fresh_project_for_discovery() {
        with_temp_project(|project| {
            use crate::daemon::protocol::SessionStartRequest;

            let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open db");
            let canonical_project = project.canonicalize().expect("canonicalize project");

            let state = start_session_direct(
                &SessionStartRequest {
                    title: "fresh-project start session".into(),
                    context: "fresh-project start".into(),
                    runtime: "claude".into(),
                    session_id: Some("daemon-start-fresh".into()),
                    project_dir: canonical_project.to_string_lossy().into_owned(),
                },
                Some(&db),
            )
            .expect("start session via db for fresh project");

            let project_id = db
                .ensure_project_for_dir(&canonical_project.to_string_lossy())
                .expect("project registered in db");
            assert_eq!(
                db.project_id_for_session(&state.session_id)
                    .expect("lookup session project id")
                    .as_deref(),
                Some(project_id.as_str())
            );

            let context_root = project_context_dir(project);
            assert!(context_root.join("project-origin.json").is_file());

            let discovered = index::discover_projects().expect("discover projects");
            assert_eq!(discovered.len(), 1);
            assert_eq!(
                discovered[0].project_dir.as_deref(),
                Some(canonical_project.as_path())
            );
        });
    }

    #[test]
    fn join_session_db_direct_adds_agent() {
        with_temp_project(|project| {
            use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

            let db = setup_db_with_project(project);

            start_session_direct(
                &SessionStartRequest {
                    title: "join test session".into(),
                    context: "join test".into(),
                    runtime: "claude".into(),
                    session_id: Some("daemon-join-1".into()),
                    project_dir: project.to_string_lossy().into(),
                },
                Some(&db),
            )
            .expect("start session");

            let joined = join_session_direct(
                "daemon-join-1",
                &SessionJoinRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    capabilities: vec![],
                    name: None,
                    project_dir: project.to_string_lossy().into(),
                    persona: None,
                },
                Some(&db),
            )
            .expect("join session via db");

            assert_eq!(joined.agents.len(), 2);

            let db_state = db
                .load_session_state("daemon-join-1")
                .expect("load")
                .expect("present");
            assert_eq!(db_state.agents.len(), 2);
        });
    }

    #[test]
    fn daemon_serve_config_default_is_unsandboxed() {
        let config = DaemonServeConfig::default();
        assert!(!config.sandboxed);
        assert_eq!(config.codex_transport, CodexTransportKind::Stdio);
    }

    fn with_isolated_transport_env<F: FnOnce()>(ws_url: Option<&str>, f: F) {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_CODEX_WS_URL", ws_url),
                ("XDG_DATA_HOME", None),
            ],
            f,
        );
    }

    #[test]
    fn codex_transport_from_env_defaults_to_stdio_when_unsandboxed() {
        with_isolated_transport_env(None, || {
            assert_eq!(codex_transport_from_env(false), CodexTransportKind::Stdio);
        });
    }

    #[test]
    fn codex_transport_from_env_defaults_to_websocket_when_sandboxed() {
        with_isolated_transport_env(None, || {
            assert_eq!(
                codex_transport_from_env(true),
                CodexTransportKind::WebSocket {
                    endpoint: super::codex_transport::DEFAULT_CODEX_WS_ENDPOINT.to_string(),
                }
            );
        });
    }

    #[test]
    fn codex_transport_from_env_overrides_via_environment() {
        with_isolated_transport_env(Some("ws://10.0.0.5:7000"), || {
            assert_eq!(
                codex_transport_from_env(false),
                CodexTransportKind::WebSocket {
                    endpoint: "ws://10.0.0.5:7000".to_string(),
                }
            );
        });
    }

    #[test]
    fn serve_rejects_non_loopback_bind_host() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            let result = runtime.block_on(async {
                tokio::time::timeout(
                    std::time::Duration::from_millis(200),
                    serve(DaemonServeConfig {
                        host: "0.0.0.0".into(),
                        ..DaemonServeConfig::default()
                    }),
                )
                .await
            });
            match result {
                Ok(Err(error)) => assert!(error.to_string().contains("loopback")),
                Ok(Ok(())) => panic!("serve should reject non-loopback hosts"),
                Err(_) => panic!("serve should fail before starting"),
            }
        });
    }

    #[test]
    fn serve_rejects_nonlocal_sandboxed_codex_websocket() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            let result = runtime.block_on(async {
                tokio::time::timeout(
                    std::time::Duration::from_millis(200),
                    serve(DaemonServeConfig {
                        sandboxed: true,
                        codex_transport: CodexTransportKind::WebSocket {
                            endpoint: "ws://10.0.0.5:7000".into(),
                        },
                        ..DaemonServeConfig::default()
                    }),
                )
                .await
            });
            match result {
                Ok(Err(error)) => assert!(error.to_string().contains("loopback")),
                Ok(Ok(())) => panic!("serve should reject remote sandboxed codex endpoints"),
                Err(_) => panic!("serve should fail before starting"),
            }
        });
    }

    #[test]
    fn run_daemon_observe_task_does_not_consume_blocking_pool_threads() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .max_blocking_threads(1)
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let observe_task = tokio::spawn(async {
                run_daemon_observe_task_with(
                    "session-a".into(),
                    PathBuf::from("/tmp/project"),
                    Duration::from_secs(1),
                    None,
                    |_session_id, _project_dir, _poll_interval, _actor_id| async {
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        Ok(0)
                    },
                )
                .await
            });

            let blocking_result =
                tokio::time::timeout(Duration::from_millis(50), tokio::task::spawn_blocking(|| 7))
                    .await
                    .expect("observe loop should leave the blocking pool available")
                    .expect("blocking task join");

            assert_eq!(blocking_result, 7);
            let observe_result = observe_task.await.expect("observe join");
            assert_eq!(observe_result.expect("observe result"), 0);
        });
    }

    #[test]
    fn sandboxed_from_env_detects_truthy_values() {
        for value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] {
            temp_env::with_var("HARNESS_SANDBOXED", Some(value), || {
                assert!(
                    sandboxed_from_env(),
                    "expected HARNESS_SANDBOXED={value} to enable sandbox mode"
                );
            });
        }
    }

    #[test]
    fn sandboxed_from_env_rejects_falsy_and_unset_values() {
        for value in ["0", "false", "no", "off", "", "anything-else"] {
            temp_env::with_var("HARNESS_SANDBOXED", Some(value), || {
                assert!(
                    !sandboxed_from_env(),
                    "expected HARNESS_SANDBOXED={value} to leave sandbox mode disabled"
                );
            });
        }
        temp_env::with_var("HARNESS_SANDBOXED", Option::<&str>::None, || {
            assert!(!sandboxed_from_env());
        });
    }

    #[test]
    fn current_log_level_defaults_to_info_when_handle_is_unavailable() {
        assert_eq!(current_log_level(), crate::DEFAULT_LOG_LEVEL);
    }

    /// Baseline: diagnostics_report returns running=false when no bridge is present.
    #[test]
    fn diagnostics_report_returns_default_bridge_when_no_bridge_running() {
        let tmp = tempdir().expect("tempdir");
        let home = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HOME", Some(home.path().to_str().expect("utf8 path"))),
                ("HARNESS_DAEMON_DATA_HOME", None),
                ("HARNESS_APP_GROUP_ID", None),
            ],
            || {
                let manifest = DaemonManifest {
                    version: "19.8.1".into(),
                    pid: 42,
                    endpoint: "http://127.0.0.1:9999".into(),
                    started_at: "2026-04-12T10:00:00Z".into(),
                    token_path: state::auth_token_path().display().to_string(),
                    sandboxed: true,
                    host_bridge: super::state::HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                state::write_manifest(&manifest).expect("manifest");

                let report = diagnostics_report(None).expect("diagnostics");
                let host_bridge = report.manifest.expect("manifest").host_bridge;

                assert!(
                    !host_bridge.running,
                    "diagnostics should return running=false when no bridge is running"
                );
            },
        );
    }

    /// Diagnostics should merge a live bridge probe so bridge state is always
    /// current even when the file-watcher chain has stalled. This test is RED
    /// before the fix lands.
    #[test]
    fn diagnostics_report_merges_live_bridge_state() {
        let tmp = tempdir().expect("tempdir");
        let home = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HOME", Some(home.path().to_str().expect("utf8 path"))),
                ("HARNESS_DAEMON_DATA_HOME", None),
                ("HARNESS_APP_GROUP_ID", None),
            ],
            || {
                // Write manifest with host_bridge.running = false (default)
                let manifest = DaemonManifest {
                    version: "19.8.1".into(),
                    pid: 42,
                    endpoint: "http://127.0.0.1:9999".into(),
                    started_at: "2026-04-12T10:00:00Z".into(),
                    token_path: state::auth_token_path().display().to_string(),
                    sandboxed: true,
                    host_bridge: super::state::HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                state::write_manifest(&manifest).expect("manifest");

                // Write bridge.json with a codex capability to the daemon root
                state::ensure_daemon_dirs().expect("dirs");
                let bridge_state_path = bridge::bridge_state_path();
                let bridge_json = serde_json::json!({
                    "socket_path": "/tmp/bridge.sock",
                    "pid": std::process::id(),
                    "started_at": "2026-04-12T10:00:00Z",
                    "token_path": "/tmp/auth-token",
                    "capabilities": {
                        "codex": {
                            "enabled": true,
                            "healthy": true,
                            "transport": "websocket",
                            "endpoint": "ws://127.0.0.1:4500",
                            "metadata": {}
                        }
                    }
                });
                fs::write(
                    &bridge_state_path,
                    serde_json::to_string_pretty(&bridge_json).expect("json"),
                )
                .expect("write bridge state");

                // Acquire the bridge lock to simulate a running bridge process
                let _bridge_lock = bridge::acquire_bridge_lock_exclusive().expect("bridge lock");

                let report = diagnostics_report(None).expect("diagnostics");
                let host_bridge = report.manifest.expect("manifest").host_bridge;

                assert!(
                    host_bridge.running,
                    "diagnostics should return live running=true bridge state"
                );
                assert!(
                    host_bridge.capabilities.contains_key("codex"),
                    "diagnostics should include the codex capability from the live bridge"
                );
            },
        );
    }
}
