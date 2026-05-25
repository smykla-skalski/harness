use super::{
    CliError, CliErrorKind, DAEMON_WIRE_VERSION, DaemonControlResponse, DaemonDiagnosticsReport,
    DaemonManifest, DaemonStatusReport, HealthResponse, LogLevelResponse, SHUTDOWN_SIGNAL,
    SetLogLevelRequest, StreamEvent, bridge, broadcast, index, launchd, state, utc_now,
};
use crate::agents::acp::probe::probe_acp_agents_cached;
use crate::daemon::db::DaemonDb;
use crate::daemon::launchd::LaunchAgentStatus;
use crate::daemon::protocol::{
    DaemonTelemetryRequest, DaemonTelemetryResponse, GitHubApiDiagnostics,
};
use crate::github_api::GitHubProtectedClient;
use crate::run::audit::scrub;
use tokio::task::{JoinError, spawn_blocking};

/// Build a point-in-time daemon status report.
///
/// # Errors
/// Returns `CliError` when the daemon database or manifest cannot be loaded.
pub fn status_report() -> Result<DaemonStatusReport, CliError> {
    let db_path = state::daemon_root().join("harness.db");
    let db = super::db::DaemonDb::open(&db_path)?;
    let (project_count, worktree_count, session_count) = db.health_counts()?;

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
        wire_version: DAEMON_WIRE_VERSION,
    })
}

/// Build the daemon health response using the async `SQLx` pool when available.
///
/// # Errors
/// Returns [`CliError`] on database failures.
pub(crate) async fn health_response_async(
    manifest: &DaemonManifest,
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<HealthResponse, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async health reads",
        ))
    })?;
    let (project_count, worktree_count, session_count) = async_db.health_counts().await?;
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
        wire_version: DAEMON_WIRE_VERSION,
    })
}

fn diagnostics_manifest_load_is_ignorable(error: &CliError) -> bool {
    if error.code() != "IO001" {
        return false;
    }
    let message = error.message().to_ascii_lowercase();
    let manifest_path = state::manifest_path()
        .display()
        .to_string()
        .to_ascii_lowercase();
    message.contains(&format!("read {manifest_path}:"))
        && (message.contains("operation not permitted") || message.contains("permission denied"))
}

fn diagnostics_manifest() -> Result<Option<DaemonManifest>, CliError> {
    match state::load_manifest() {
        Ok(manifest) => Ok(manifest.map(enrich_diagnostics_manifest)),
        Err(error) => handle_diagnostics_manifest_error(error),
    }
}

async fn diagnostics_manifest_async() -> Result<Option<DaemonManifest>, CliError> {
    spawn_blocking(diagnostics_manifest)
        .await
        .unwrap_or_else(|error| Err(blocking_join_error("daemon diagnostics manifest", &error)))
}

fn enrich_diagnostics_manifest(mut manifest: DaemonManifest) -> DaemonManifest {
    if let Ok(live_bridge) = bridge::host_bridge_manifest_with_discovery() {
        manifest.host_bridge = live_bridge;
    }
    manifest
}

fn handle_diagnostics_manifest_error(error: CliError) -> Result<Option<DaemonManifest>, CliError> {
    if !diagnostics_manifest_load_is_ignorable(&error) {
        return Err(error);
    }

    log_ignored_diagnostics_manifest_error(&error);
    Ok(None)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_ignored_diagnostics_manifest_error(error: &CliError) {
    tracing::warn!(
        error = %error,
        path = %state::manifest_path().display(),
        "diagnostics skipping unreadable daemon manifest"
    );
}

/// Build a richer diagnostics report for the daemon settings screen.
///
/// # Errors
/// Returns `CliError` when daemon state cannot be loaded.
pub fn diagnostics_report(
    db: Option<&super::db::DaemonDb>,
) -> Result<DaemonDiagnosticsReport, CliError> {
    let manifest = diagnostics_manifest()?;
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
        acp_runtime_probe: probe_acp_agents_cached(),
        github_api: None,
        workspace: state::diagnostics()?,
        recent_events: state::read_recent_events(16)?,
    })
}

/// Build a richer diagnostics report for the daemon settings screen using
/// the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when daemon state cannot be loaded.
pub(crate) async fn diagnostics_report_async(
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<DaemonDiagnosticsReport, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async diagnostics reads",
        ))
    })?;
    let manifest = diagnostics_manifest_async().await?;
    let health = if let Some(manifest) = manifest.as_ref() {
        Some(health_response_async(manifest, Some(async_db)).await?)
    } else {
        None
    };

    diagnostics_from_async_db(async_db, manifest, health).await
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
        acp_runtime_probe: probe_acp_agents_cached(),
        github_api: None,
        workspace,
        recent_events,
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "cached diagnostics keep explicit fallback branches per source"
)]
async fn diagnostics_from_async_db(
    async_db: &super::db::AsyncDaemonDb,
    manifest: Option<DaemonManifest>,
    health: Option<HealthResponse>,
) -> Result<DaemonDiagnosticsReport, CliError> {
    let launch_agent = match async_db.load_cached_launch_agent_status().await? {
        Some(cached) => cached,
        None => launch_agent_status_async().await?,
    };
    let workspace = match async_db.load_cached_workspace_diagnostics().await? {
        Some(cached) => cached,
        None => workspace_diagnostics_async().await?,
    };
    let recent_events = async_db.load_recent_daemon_events(16).await?;

    Ok(DaemonDiagnosticsReport {
        health,
        manifest,
        launch_agent,
        acp_runtime_probe: probe_acp_agents_cached(),
        github_api: Some(github_api_status_async().await),
        workspace,
        recent_events,
    })
}

pub(crate) async fn github_api_status_async() -> GitHubApiDiagnostics {
    GitHubProtectedClient::status().await.into()
}

async fn launch_agent_status_async() -> Result<LaunchAgentStatus, CliError> {
    spawn_blocking(launchd::launch_agent_status)
        .await
        .map_err(|error| blocking_join_error("daemon launch agent status", &error))
}

async fn workspace_diagnostics_async() -> Result<state::DaemonDiagnostics, CliError> {
    spawn_blocking(state::diagnostics)
        .await
        .unwrap_or_else(|error| Err(blocking_join_error("daemon workspace diagnostics", &error)))
}

fn blocking_join_error(operation: &str, error: &JoinError) -> CliError {
    CliErrorKind::workflow_io(format!("join {operation} worker: {error}")).into()
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

pub(crate) fn current_log_level() -> String {
    crate::log_filter_handle().map_or_else(
        || crate::DEFAULT_LOG_LEVEL.to_string(),
        |handle| {
            handle
                .with_current(|filter| {
                    let filter_string = filter.to_string();
                    for level in state::VALID_LOG_LEVELS {
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

/// Record client-side decode failure telemetry into daemon diagnostics.
///
/// # Errors
/// Returns [`CliError`] when validation fails or the daemon audit event cannot
/// be persisted.
pub fn record_telemetry(
    request: &DaemonTelemetryRequest,
    db: Option<&DaemonDb>,
) -> Result<DaemonTelemetryResponse, CliError> {
    let source = request.source.trim();
    if source.is_empty() {
        return Err(CliErrorKind::workflow_parse("telemetry source cannot be empty").into());
    }
    let message = request.message.trim();
    if message.is_empty() {
        return Err(CliErrorKind::workflow_parse("telemetry message cannot be empty").into());
    }
    let scrubbed_source = scrub(source);

    let mut event_message = format!(
        "client telemetry {} from {}: {}",
        request.kind.as_str(),
        scrubbed_source,
        scrub(message)
    );
    if let Some(sample) = request.sample.as_deref().map(str::trim)
        && !sample.is_empty()
    {
        event_message.push_str(" sample=");
        event_message.push_str(&scrub(sample));
    }

    let event = state::DaemonAuditEvent {
        recorded_at: utc_now(),
        level: "warn".to_string(),
        message: event_message,
    };
    state::append_event_entry(&event)?;
    if let Some(db) = db {
        db.append_daemon_event(&event.recorded_at, &event.level, &event.message)?;
    }
    Ok(DaemonTelemetryResponse {
        recorded_at: event.recorded_at,
    })
}

pub(crate) fn validate_and_reload_filter(level: &str) -> Result<LogLevelResponse, CliError> {
    let directive = format!("harness={level}");
    reload_filter(&directive)?;
    Ok(LogLevelResponse {
        level: level.to_string(),
        filter: directive,
    })
}

fn reload_filter(directive: &str) -> Result<(), CliError> {
    let handle = crate::log_filter_handle()
        .ok_or_else(|| CliErrorKind::workflow_io("log filter handle unavailable"))?;
    let filter = tracing_subscriber::EnvFilter::try_new(directive).map_err(|error| {
        CliErrorKind::workflow_parse(format!("parse log filter '{directive}': {error}"))
    })?;
    handle
        .reload(filter)
        .map_err(|error| CliErrorKind::workflow_io(format!("reload log filter: {error}")).into())
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
    let level = state::parse_log_level(&request.level)?;

    let previous = get_log_level()?;
    let response = validate_and_reload_filter(&level)?;
    if let Err(error) = state::persist_log_level(Some(&level)) {
        let rollback = reload_filter(&previous.filter);
        return Err(match rollback {
            Ok(()) => error,
            Err(rollback_error) => CliErrorKind::workflow_io(format!(
                "persist daemon log level: {error}; restore previous log filter: {rollback_error}"
            ))
            .into(),
        });
    }

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
