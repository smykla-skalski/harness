mod binary_stamp;

use super::{
    Arc, CliError, CliErrorKind, CodexControllerHandle, CodexTransportKind, DaemonHttpState,
    DaemonManifest, DaemonObserveRuntime, DaemonServeConfig, Duration, Mutex, OBSERVE_RUNTIME,
    OnceLock, Path, ReplayBuffer, SHUTDOWN_SIGNAL, SessionStatus, TcpListener, bridge, broadcast,
    env, http, index, log_sandbox_startup, process_id, state, tokio_watch, utc_now, watch,
};
use crate::daemon::http::AsyncDaemonDbSlot;
use crate::telemetry::current_trace_id;
use std::time::Instant;
use tracing::Instrument as _;
use tracing::field::{Empty, display};

use binary_stamp::current_binary_stamp;

/// Migrate the harness data root from the legacy macOS location; logs on failure.
#[cfg(target_os = "macos")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn run_data_root_migration() {
    use crate::{sandbox::migration::migrate, workspace::{harness_data_root, legacy_macos_root}};
    if let Err(err) = migrate(&legacy_macos_root(), &harness_data_root()) {
        tracing::warn!(%err, "data-root migration failed; continuing with new root");
    }
}
/// Start the daemon TCP server and service all incoming connections.
///
/// # Errors
/// Returns [`CliError`] if the server fails to start or bind.
pub async fn serve(config: DaemonServeConfig) -> Result<(), CliError> {
    #[cfg(target_os = "macos")]
    run_data_root_migration();

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
    let async_db: Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>> = Arc::new(OnceLock::new());
    let _ = OBSERVE_RUNTIME.set(DaemonObserveRuntime {
        sender: sender.clone(),
        poll_interval: config.observe_interval,
        running_sessions: Arc::default(),
        db: db.clone(),
        async_db: async_db.clone(),
    });
    let _ = SHUTDOWN_SIGNAL.set(shutdown_tx.clone());
    let replay_buffer = Arc::new(Mutex::new(ReplayBuffer::new(512)));
    let daemon_epoch = manifest.started_at.clone();

    if let Err(error) =
        initialize_startup_state(&db, &async_db, sender.clone(), config.poll_interval).await
    {
        let _ = state::clear_manifest_for_pid(process_id());
        return Err(error);
    }
    let codex_controller = CodexControllerHandle::new_with_async_db(
        sender.clone(),
        db.clone(),
        async_db.clone(),
        config.sandboxed,
    );
    let agent_tui_manager = super::agent_tui::AgentTuiManagerHandle::new_with_async_db(
        sender.clone(),
        db.clone(),
        async_db.clone(),
        config.sandboxed,
    );
    let _bridge_watcher = bridge::spawn_manifest_watcher();

    let app_state = DaemonHttpState {
        token,
        sender,
        manifest,
        daemon_epoch,
        replay_buffer,
        db,
        async_db: AsyncDaemonDbSlot::from_inner(async_db),
        db_path: Some(state::daemon_root().join("harness.db")),
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
) -> Result<Arc<Mutex<super::db::DaemonDb>>, CliError> {
    let db_path = state::daemon_root().join("harness.db");
    let db = open_daemon_db(&db_path)?;
    let db = Arc::new(Mutex::new(db));
    let _ = db_slot.set(Arc::clone(&db));
    tracing::info!("database ready");
    Ok(db)
}

pub(crate) fn initialize_db_and_spawn_background_tasks(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
    sender: broadcast::Sender<super::protocol::StreamEvent>,
    poll_interval: Duration,
) -> Result<(), CliError> {
    let db = open_and_publish_db(db_slot)?;
    let _watch = watch::spawn_watch_loop(
        sender,
        poll_interval,
        Some(Arc::clone(&db)),
        Arc::clone(async_db_slot),
    );
    run_background_reconciliation(&db);
    Ok(())
}

pub(crate) async fn initialize_startup_state(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
    sender: broadcast::Sender<super::protocol::StreamEvent>,
    poll_interval: Duration,
) -> Result<(), CliError> {
    let span = startup_span();
    if let Some(trace_id) = span.in_scope(current_trace_id) {
        span.record("trace_id", display(trace_id));
    }
    let started_at = Instant::now();
    let result = async {
        initialize_db_and_spawn_background_tasks(db_slot, async_db_slot, sender, poll_interval)?;
        initialize_async_db(async_db_slot).await
    }
    .instrument(span.clone())
    .await;

    let duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
    span.record("duration_ms", display(duration_ms));
    span.record("error", display(result.is_err()));
    if let Err(error) = &result {
        span.record("error_message", display(error));
    }

    result
}

pub(crate) async fn initialize_async_db(
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
) -> Result<(), CliError> {
    let db = open_and_publish_async_db(async_db_slot).await?;
    db.cache_startup_diagnostics().await?;
    let _ = db.health_counts().await?;
    Ok(())
}

fn startup_span() -> tracing::Span {
    tracing::info_span!(
        parent: None,
        "daemon.lifecycle.startup",
        otel.name = "daemon.lifecycle.startup",
        otel.kind = "internal",
        "daemon.phase" = "startup",
        duration_ms = Empty,
        error = Empty,
        error_message = Empty,
        trace_id = Empty
    )
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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) async fn open_and_publish_async_db(
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
) -> Result<Arc<super::db::AsyncDaemonDb>, CliError> {
    let db_path = state::daemon_root().join("harness.db");
    let db = Arc::new(open_daemon_async_db(&db_path).await?);
    let _ = async_db_slot.set(Arc::clone(&db));
    tracing::info!("async database pool ready");
    Ok(db)
}

pub(crate) fn open_daemon_db(path: &Path) -> Result<super::db::DaemonDb, CliError> {
    super::db::DaemonDb::open(path).inspect_err(|error| {
        let message = format!("failed to open daemon database: {error}");
        let _ = state::append_event("warn", &message);
    })
}

pub(crate) async fn open_daemon_async_db(
    path: &Path,
) -> Result<super::db::AsyncDaemonDb, CliError> {
    super::db::AsyncDaemonDb::connect(path)
        .await
        .inspect_err(|error| {
            let message = format!("failed to open daemon async database pool: {error}");
            let _ = state::append_event("warn", &message);
        })
}
