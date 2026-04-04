use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::id as process_id;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use crate::agents::runtime as agents_runtime;
use crate::agents::service as agents_service;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::session::types::{SessionLogEntry, SessionState, SessionTransition, TaskSource};
use crate::session::{observe as session_observe, service as session_service};
use crate::workspace::utc_now;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, watch as tokio_watch};
use tokio::task::spawn_blocking;

use super::http::{self, DaemonHttpState};
use super::index::{self, ResolvedSession};
use super::launchd::{self, LaunchAgentStatus};
use super::protocol::{
    AgentRemoveRequest, DaemonControlResponse, DaemonDiagnosticsReport, HealthResponse,
    LeaderTransferRequest, ObserveSessionRequest, ProjectSummary, ReadyEventPayload,
    RoleChangeRequest, SessionDetail, SessionEndRequest, SessionExtensionsPayload, SessionSummary,
    SessionUpdatedPayload, SessionsUpdatedPayload, SignalSendRequest, StreamEvent,
    TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskUpdateRequest, TimelineEntry,
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
    running_sessions: Arc<Mutex<BTreeSet<String>>>,
    db: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
}

static OBSERVE_RUNTIME: OnceLock<DaemonObserveRuntime> = OnceLock::new();
static SHUTDOWN_SIGNAL: OnceLock<tokio_watch::Sender<bool>> = OnceLock::new();

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
}

impl Default for DaemonServeConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            poll_interval: Duration::from_secs(2),
            observe_interval: Duration::from_secs(5),
        }
    }
}

/// Run the local daemon HTTP server until the process exits.
///
/// # Errors
/// Returns `CliError` on bind or filesystem failures.
pub async fn serve(config: DaemonServeConfig) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
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

    spawn_background_db_init(db.clone(), sender.clone(), config.poll_interval);

    let app_state = DaemonHttpState {
        token,
        sender,
        manifest,
        daemon_epoch,
        replay_buffer,
        db,
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

fn spawn_background_db_init(
    db_slot: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    sender: broadcast::Sender<super::protocol::StreamEvent>,
    poll_interval: Duration,
) {
    tokio::spawn(async move {
        let db = spawn_blocking(move || open_and_publish_db(&db_slot))
            .await
            .ok()
            .flatten();

        let Some(db) = db else {
            return;
        };

        let db_option = Some(Arc::clone(&db));
        let _watch = watch::spawn_watch_loop(sender, poll_interval, db_option.clone());
        spawn_background_reconciliation(db_option.clone());
        spawn_background_diagnostics(db_option);
    });
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
    let Ok(db_guard) = db.lock() else {
        return;
    };
    match db_guard.reconcile_from_files() {
        Ok(result) => {
            let message = format!(
                "background reconciliation: {} projects, {} sessions imported, {} skipped",
                result.projects, result.sessions_imported, result.sessions_skipped
            );
            tracing::info!("{message}");
            let _ = state::append_event("info", &message);
        }
        Err(error) => {
            tracing::warn!(%error, "background file reconciliation failed");
            let _ = state::append_event(
                "warn",
                &format!("background file reconciliation failed: {error}"),
            );
        }
    }
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
        manifest: state::load_manifest()?,
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
    let manifest = state::load_manifest()?;
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
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return timeline::session_timeline_from_resolved_with_db(&resolved, db);
    }
    timeline::session_timeline(session_id)
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
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return snapshot::build_session_extensions(&resolved, Some(db));
    }
    let resolved = index::resolve_session(session_id)?;
    snapshot::build_session_extensions(&resolved, None)
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
        let from_status = session_service::apply_update_task(
            &mut state,
            task_id,
            request.status,
            request.note.as_deref(),
            &request.actor,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_status_changed(task_id, from_status, request.status),
            Some(&request.actor),
            None,
        ))?;
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
        session_service::apply_remove_agent(&mut state, agent_id, &request.actor, &utc_now())?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_removed(agent_id),
            Some(&request.actor),
            None,
        ))?;
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
        session_service::apply_end_session(&mut state, &request.actor, &utc_now())?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.mark_session_inactive(session_id)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_session_ended(),
            Some(&request.actor),
            None,
        ))?;
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
) -> Result<SessionDetail, CliError> {
    // Resolve project_dir (needed for signal file writes regardless of path).
    let project_dir = if let Some(db) = db
        && let Some(dir) = db.project_dir_for_session(session_id)?
    {
        PathBuf::from(dir)
    } else {
        let resolved = index::resolve_session(session_id)?;
        effective_project_dir(&resolved).to_path_buf()
    };

    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        // DB-direct: apply state mutation to SQLite, then write signal file.
        let now = utc_now();
        let (runtime_name, target_agent_session_id) = session_service::apply_send_signal_state(
            &mut state,
            &request.agent_id,
            &request.actor,
            &now,
        )?;
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
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    // File-based fallback
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
        let project_id = db.ensure_project_for_dir(&request.project_dir)?;
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

/// Join an existing session, writing directly to `SQLite` when a DB is available.
///
/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or DB operations fail.
pub fn join_session_direct(
    session_id: &str,
    request: &super::protocol::SessionJoinRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
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
    )
}

/// Record a signal acknowledgment, delegating to the session service.
///
/// # Errors
/// Returns `CliError` on log read/write failures.
pub fn record_signal_ack_direct(
    session_id: &str,
    request: &super::protocol::SignalAckRequest,
) -> Result<(), CliError> {
    let project_dir = Path::new(&request.project_dir);
    session_service::record_signal_acknowledgment(
        session_id,
        &request.agent_id,
        &request.signal_id,
        request.result,
        project_dir,
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
    let actor_id = request.and_then(|request| request.actor.as_deref());

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

    if !start_daemon_observe_loop(session_id, &project_dir, actor_id) {
        let _ = session_observe::run_session_observe(session_id, &project_dir, actor_id)?;
    }
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
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

fn session_not_found(session_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
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

fn start_daemon_observe_loop(session_id: &str, project_dir: &Path, actor_id: Option<&str>) -> bool {
    let Some(runtime) = OBSERVE_RUNTIME.get().cloned() else {
        return false;
    };

    {
        let Ok(mut running_sessions) = runtime.running_sessions.lock() else {
            return false;
        };
        if !running_sessions.insert(session_id.to_string()) {
            return true;
        }
    }

    let session_id = session_id.to_string();
    let project_dir = project_dir.to_path_buf();
    let actor_id = actor_id.map(ToString::to_string);
    tokio::spawn(async move {
        let poll_interval_seconds = runtime.poll_interval.as_secs().max(1);
        let session_id_for_watch = session_id.clone();
        let project_dir_for_watch = project_dir.clone();
        let actor_id_for_watch = actor_id.clone();
        let result = spawn_blocking(move || {
            session_observe::execute_session_watch(
                &session_id_for_watch,
                &project_dir_for_watch,
                poll_interval_seconds,
                false,
                actor_id_for_watch.as_deref(),
            )
        })
        .await;
        if let Err(error) = result {
            tracing::warn!(%error, session_id, "daemon observe loop task failed");
        } else if let Ok(Err(error)) = result {
            tracing::warn!(%error, session_id, "daemon observe loop exited with error");
        }
        if let Ok(mut running_sessions) = runtime.running_sessions.lock() {
            running_sessions.remove(&session_id);
        }
        let db_guard = runtime.db.get().and_then(|db| db.lock().ok());
        let db_ref = db_guard.as_deref();
        sync_after_mutation(db_ref, &session_id);
        broadcast_session_snapshot(&runtime.sender, &session_id, db_ref);
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::Path;
    use std::process::Command;

    use fs_err as fs;
    use tempfile::tempdir;

    use crate::agents::runtime;
    use crate::daemon::protocol::{SessionUpdatedPayload, SessionsUpdatedPayload};
    use crate::hooks::adapters::HookAgent;
    use crate::session::{
        service as session_service,
        types::{SessionRole, SessionSignalStatus},
    };
    use crate::workspace::project_context_dir;

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("xdg path")),
                ),
                ("CLAUDE_SESSION_ID", Some("leader-session")),
            ],
            || {
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
            },
        );
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

    /// Build an in-memory DB with a project and session loaded from files.
    #[expect(
        dead_code,
        reason = "used by future DB-direct tests that also need file state"
    )]
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
        use crate::workspace::project_context_dir;

        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open in-memory db");

        let context_root = project_context_dir(project);
        let project_record = super::index::DiscoveredProject {
            project_id: format!("project-{}", hex_digest(project)),
            name: "test".into(),
            project_dir: Some(project.to_path_buf()),
            repository_root: Some(project.to_path_buf()),
            checkout_id: "checkout-test".into(),
            checkout_name: "test".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
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

    fn hex_digest(path: &Path) -> String {
        use std::hash::{DefaultHasher, Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        path.hash(&mut hasher);
        format!("{:016x}", hasher.finish())
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
    fn end_session_db_direct_marks_inactive() {
        with_temp_project(|project| {
            let (db, state) = setup_db_only_session(project);
            let leader_id = state.leader_id.expect("leader id");

            let _ = end_session(
                &state.session_id,
                &SessionEndRequest { actor: leader_id },
                Some(&db),
            )
            .expect("end session via db");

            let db_state = db
                .load_session_state(&state.session_id)
                .expect("load state")
                .expect("state present");
            assert_eq!(db_state.status, crate::session::types::SessionStatus::Ended);
        });
    }

    #[test]
    fn observe_session_with_actor_creates_tasks() {
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

            let detail = observe_session(
                &state.session_id,
                Some(&ObserveSessionRequest {
                    actor: Some(leader_id),
                }),
                None,
            )
            .expect("observe session");

            assert_eq!(detail.tasks.len(), 1);
            assert_eq!(
                detail.tasks[0].source,
                crate::session::types::TaskSource::Observe
            );
        });
    }

    fn setup_db_with_project(project: &Path) -> crate::daemon::db::DaemonDb {
        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open db");
        let context_root = project_context_dir(project);
        let project_record = index::DiscoveredProject {
            project_id: format!("project-{}", hex_digest(project)),
            name: "test".into(),
            project_dir: Some(project.to_path_buf()),
            repository_root: Some(project.to_path_buf()),
            checkout_id: "checkout-test".into(),
            checkout_name: "test".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
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
}
