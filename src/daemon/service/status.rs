use super::{
    CliError, CliErrorKind, DaemonControlResponse, DaemonDiagnosticsReport, DaemonManifest,
    DaemonStatusReport, HealthResponse, LogLevelResponse, SHUTDOWN_SIGNAL, SetLogLevelRequest,
    StreamEvent, bridge, broadcast, index, launchd, snapshot, state, utc_now,
};

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

pub(crate) fn diagnostics_from_db(
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

pub(crate) fn current_log_level() -> String {
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

pub(crate) fn validate_and_reload_filter(level: &str) -> Result<LogLevelResponse, CliError> {
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
