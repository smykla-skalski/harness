use super::{
    Arc, CliError, CliErrorKind, CodexControllerHandle, CodexTransportKind, DaemonHttpState,
    DaemonManifest, DaemonObserveRuntime, DaemonServeConfig, Duration, Mutex, OBSERVE_RUNTIME,
    OnceLock, Path, ReplayBuffer, SHUTDOWN_SIGNAL, SessionStatus, TcpListener, bridge, broadcast,
    env, http, index, log_sandbox_startup, process_id, spawn_blocking, state, tokio_watch, utc_now,
    watch,
};
use std::env as std_env;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

/// Start the daemon TCP server and service all incoming connections.
///
/// # Errors
/// Returns [`CliError`] if the server fails to start or bind.
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
    let binary_stamp = current_binary_stamp();

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
        binary_stamp,
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

fn current_binary_stamp() -> Option<state::DaemonBinaryStamp> {
    let helper_path = current_binary_path()?;
    let metadata = current_binary_metadata(&helper_path)?;
    let modification_time_interval_since_1970 = metadata_modification_time(&metadata)?;

    Some(state::DaemonBinaryStamp {
        helper_path: helper_path.display().to_string(),
        device_identifier: metadata.dev(),
        inode: metadata.ino(),
        file_size: metadata.size(),
        modification_time_interval_since_1970,
    })
}

fn current_binary_path() -> Option<PathBuf> {
    match std_env::current_exe() {
        Ok(path) => Some(path),
        Err(error) => log_current_binary_path_error(&error),
    }
}

fn current_binary_metadata(helper_path: &Path) -> Option<fs::Metadata> {
    match fs::metadata(helper_path) {
        Ok(metadata) => Some(metadata),
        Err(error) => log_current_binary_metadata_error(helper_path, &error),
    }
}

fn metadata_modification_time(metadata: &fs::Metadata) -> Option<f64> {
    let seconds = metadata_mtime_seconds(metadata)?;
    let nanos = metadata_mtime_nanos(metadata)?;
    Some(Duration::new(seconds, nanos).as_secs_f64())
}

fn metadata_mtime_seconds(metadata: &fs::Metadata) -> Option<u64> {
    match u64::try_from(metadata.mtime()) {
        Ok(seconds) => Some(seconds),
        Err(_) => log_negative_mtime(metadata.mtime()),
    }
}

fn metadata_mtime_nanos(metadata: &fs::Metadata) -> Option<u32> {
    match u32::try_from(metadata.mtime_nsec()) {
        Ok(nanos) => Some(nanos),
        Err(_) => log_invalid_mtime_nanos(metadata.mtime_nsec()),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_current_binary_path_error(error: &io::Error) -> Option<PathBuf> {
    tracing::warn!(%error, "failed to resolve current daemon binary path");
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_current_binary_metadata_error(
    helper_path: &Path,
    error: &io::Error,
) -> Option<fs::Metadata> {
    tracing::warn!(
        path = %helper_path.display(),
        %error,
        "failed to stat current daemon binary"
    );
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_negative_mtime(seconds: i64) -> Option<u64> {
    tracing::warn!(
        seconds,
        "current daemon binary has a negative modification timestamp"
    );
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_invalid_mtime_nanos(nanos: i64) -> Option<u32> {
    tracing::warn!(
        nanos,
        "current daemon binary has an invalid nanosecond timestamp"
    );
    None
}

pub(crate) fn validate_serve_config(config: &DaemonServeConfig) -> Result<(), CliError> {
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
pub(crate) fn open_and_publish_db(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
) -> Option<Arc<Mutex<super::db::DaemonDb>>> {
    let db_path = state::daemon_root().join("harness.db");
    let db = open_daemon_db(&db_path)?;
    let db = Arc::new(Mutex::new(db));
    let _ = db_slot.set(Arc::clone(&db));
    tracing::info!("database ready");
    Some(db)
}

pub(crate) fn initialize_db_and_spawn_background_tasks(
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

pub(crate) fn spawn_background_reconciliation(db: Option<Arc<Mutex<super::db::DaemonDb>>>) {
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
pub(crate) fn run_background_reconciliation(db: &Arc<Mutex<super::db::DaemonDb>>) {
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

pub(crate) fn discover_background_reconciliation_inputs() -> Result<
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

pub(crate) fn sync_background_projects_and_collect_candidates(
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

pub(crate) fn sync_background_projects(
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

pub(crate) fn collect_background_session_candidates(
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

pub(crate) fn prepare_background_session_import(
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

pub(crate) fn session_import_required(
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
pub(crate) fn log_background_session_prepare_error(
    error: &CliError,
    resolved: &super::index::ResolvedSession,
) {
    tracing::warn!(
        %error,
        session_id = %resolved.state.session_id,
        "background session prepare failed"
    );
}

pub(crate) fn prepared_session_import_required(
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
pub(crate) fn log_background_session_version_check_error(
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
pub(crate) fn log_background_session_import_error(
    error: &CliError,
    prepared: &super::db::PreparedSessionResync,
) {
    tracing::warn!(
        %error,
        session_id = %prepared.resolved.state.session_id,
        "background session import failed"
    );
}

pub(crate) fn spawn_background_diagnostics(db: Option<Arc<Mutex<super::db::DaemonDb>>>) {
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

pub(crate) fn open_daemon_db(path: &Path) -> Option<super::db::DaemonDb> {
    super::db::DaemonDb::open(path)
        .inspect_err(|error| {
            let message = format!("failed to open daemon database: {error}");
            let _ = state::append_event("warn", &message);
        })
        .ok()
}
