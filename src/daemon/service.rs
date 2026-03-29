use std::path::Path;
use std::process::id as process_id;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::broadcast;

use crate::errors::{CliError, CliErrorKind};
use crate::session::{observe as session_observe, service as session_service};
use crate::workspace::utc_now;

use super::http::{self, DaemonHttpState};
use super::index::{self, ResolvedSession};
use super::launchd::{self, LaunchAgentStatus};
use super::protocol::{
    AgentRemoveRequest, DaemonDiagnosticsReport, HealthResponse, LeaderTransferRequest,
    ObserveSessionRequest, ProjectSummary, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionSummary, SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskUpdateRequest, TimelineEntry,
};
use super::snapshot;
use super::state::{self, DaemonDiagnostics, DaemonManifest};
use super::timeline;
use super::watch;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatusReport {
    pub manifest: Option<DaemonManifest>,
    pub launch_agent: LaunchAgentStatus,
    pub project_count: usize,
    pub session_count: usize,
    pub diagnostics: DaemonDiagnostics,
}

#[derive(Debug, Clone)]
pub struct DaemonServeConfig {
    pub host: String,
    pub port: u16,
    pub poll_interval: Duration,
}

impl Default for DaemonServeConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            poll_interval: Duration::from_secs(2),
        }
    }
}

/// Run the local daemon HTTP server until the process exits.
///
/// # Errors
/// Returns `CliError` on bind or filesystem failures.
pub async fn serve(config: DaemonServeConfig) -> Result<(), CliError> {
    state::ensure_daemon_dirs()?;
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
    let _watch = watch::spawn_watch_loop(sender.clone(), config.poll_interval);
    let app_state = DaemonHttpState {
        token,
        sender,
        manifest,
    };

    http::serve(listener, app_state).await
}

/// Build a point-in-time daemon status report.
///
/// # Errors
/// Returns `CliError` on discovery failures.
pub fn status_report() -> Result<DaemonStatusReport, CliError> {
    let projects = snapshot::project_summaries()?;
    let sessions = snapshot::session_summaries(true)?;
    Ok(DaemonStatusReport {
        manifest: state::load_manifest()?,
        launch_agent: launchd::launch_agent_status(),
        project_count: projects.len(),
        session_count: sessions.len(),
        diagnostics: state::diagnostics()?,
    })
}

/// Build the daemon health response exposed on `/v1/health`.
///
/// # Errors
/// Returns `CliError` on discovery failures.
pub fn health_response(manifest: &DaemonManifest) -> Result<HealthResponse, CliError> {
    let projects = snapshot::project_summaries()?;
    let sessions = snapshot::session_summaries(true)?;
    Ok(HealthResponse {
        status: "ok".into(),
        version: manifest.version.clone(),
        pid: manifest.pid,
        endpoint: manifest.endpoint.clone(),
        started_at: manifest.started_at.clone(),
        project_count: projects.len(),
        session_count: sessions.len(),
    })
}

/// Build a richer diagnostics report for the daemon preferences screen.
///
/// # Errors
/// Returns `CliError` when daemon state cannot be loaded.
pub fn diagnostics_report() -> Result<DaemonDiagnosticsReport, CliError> {
    let manifest = state::load_manifest()?;
    let health = manifest.as_ref().map(health_response).transpose()?;
    Ok(DaemonDiagnosticsReport {
        health,
        manifest,
        launch_agent: launchd::launch_agent_status(),
        workspace: state::diagnostics()?,
        recent_events: state::read_recent_events(16)?,
    })
}

/// List discovered projects known to the daemon.
///
/// # Errors
/// Returns `CliError` on project discovery failures.
pub fn list_projects() -> Result<Vec<ProjectSummary>, CliError> {
    snapshot::project_summaries()
}

/// List discovered sessions across all indexed projects.
///
/// # Errors
/// Returns `CliError` on project or session discovery failures.
pub fn list_sessions(include_all: bool) -> Result<Vec<SessionSummary>, CliError> {
    snapshot::session_summaries(include_all)
}

/// Load a single session detail snapshot.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or loaded.
pub fn session_detail(session_id: &str) -> Result<SessionDetail, CliError> {
    snapshot::session_detail(session_id)
}

/// Load a merged session timeline.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or timeline sources fail.
pub fn session_timeline(session_id: &str) -> Result<Vec<TimelineEntry>, CliError> {
    timeline::session_timeline(session_id)
}

/// Create a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task creation fails.
pub fn create_task(
    session_id: &str,
    request: &TaskCreateRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    let _ = session_service::create_task(
        session_id,
        &request.title,
        request.context.as_deref(),
        request.severity,
        &request.actor,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// Assign a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or assignment fails.
pub fn assign_task(
    session_id: &str,
    task_id: &str,
    request: &TaskAssignRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    session_service::assign_task(
        session_id,
        task_id,
        &request.agent_id,
        &request.actor,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// Update a task status through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the update fails.
pub fn update_task(
    session_id: &str,
    task_id: &str,
    request: &TaskUpdateRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    session_service::update_task(
        session_id,
        task_id,
        request.status,
        request.note.as_deref(),
        &request.actor,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// Record a task checkpoint through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or checkpointing fails.
pub fn checkpoint_task(
    session_id: &str,
    task_id: &str,
    request: &TaskCheckpointRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    let _ = session_service::record_task_checkpoint(
        session_id,
        task_id,
        &request.actor,
        &request.summary,
        request.progress,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// Change an agent role through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub fn change_role(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    session_service::assign_role(
        session_id,
        agent_id,
        request.role,
        &request.actor,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// Remove an agent through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the removal fails.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    session_service::remove_agent(session_id, agent_id, &request.actor, project_dir)?;
    snapshot::session_detail(session_id)
}

/// Transfer session leadership through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub fn transfer_leader(
    session_id: &str,
    request: &LeaderTransferRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    session_service::transfer_leader(
        session_id,
        &request.new_leader_id,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// End a session through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub fn end_session(
    session_id: &str,
    request: &SessionEndRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    session_service::end_session(session_id, &request.actor, project_dir)?;
    snapshot::session_detail(session_id)
}

/// Send a signal through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or signal delivery setup fails.
pub fn send_signal(
    session_id: &str,
    request: &SignalSendRequest,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    let _ = session_service::send_signal(
        session_id,
        &request.agent_id,
        &request.command,
        &request.message,
        request.action_hint.as_deref(),
        &request.actor,
        project_dir,
    )?;
    snapshot::session_detail(session_id)
}

/// Trigger a one-shot session observation pass.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or observe fails.
pub fn observe_session(
    session_id: &str,
    request: Option<&ObserveSessionRequest>,
) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let project_dir = require_project_dir(&resolved)?;
    let actor_id = request.and_then(|request| request.actor.as_deref());
    let _ = session_observe::run_session_observe(session_id, project_dir, actor_id)?;
    snapshot::session_detail(session_id)
}

pub fn refresh_event(event: &str, session_id: Option<&str>) -> StreamEvent {
    StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serde_json::json!({ "ok": true }),
    }
}

fn require_project_dir(resolved: &ResolvedSession) -> Result<&Path, CliError> {
    resolved.project.project_dir.as_deref().ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "project path unavailable for session '{}' in project '{}'",
            resolved.state.session_id, resolved.project.project_id
        )))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::Path;

    use fs_err as fs;
    use tempfile::tempdir;

    use crate::agents::runtime;
    use crate::hooks::adapters::HookAgent;
    use crate::session::{service as session_service, types::SessionRole};
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

                let report = diagnostics_report().expect("diagnostics");

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
    fn observe_session_with_actor_creates_tasks() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "observe test",
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
            )
            .expect("observe session");

            assert_eq!(detail.tasks.len(), 1);
            assert_eq!(
                detail.tasks[0].source,
                crate::session::types::TaskSource::Observe
            );
        });
    }
}
