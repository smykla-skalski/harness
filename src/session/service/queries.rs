use super::{
    CliError, CliErrorKind, DaemonClient, Path, PathBuf, SessionMetrics, SessionRole, SessionState,
    SessionStatus, daemon_index, detail_to_session_state, load_state_or_err,
    reconcile_expired_pending_signals, storage, summary_to_session_state, validate_policy_preset,
};
use crate::daemon::agent_tui::AgentTuiStartRequest;

/// Load the current session state.
///
/// # Errors
/// Returns `CliError` if the session is not found.
pub fn session_status(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        let mut state = detail_to_session_state(&detail);
        state.metrics = SessionMetrics::recalculate(&state);
        return Ok(state);
    }

    reconcile_expired_pending_signals(session_id, project_dir)?;
    let mut state = load_state_or_err(session_id, project_dir)?;
    state.metrics = SessionMetrics::recalculate(&state);
    Ok(state)
}

/// Build the managed TUI start request used for preset-driven leader recovery.
///
/// # Errors
/// Returns `CliError` when the preset is unsupported, the session is not
/// leaderless degraded, or the session policy does not allow the requested
/// recovery preset.
pub fn build_recovery_tui_request(
    session_id: &str,
    preset: &str,
    runtime_name: &str,
    project_dir: &Path,
) -> Result<AgentTuiStartRequest, CliError> {
    validate_policy_preset(Some(preset))?;
    let state = session_status(session_id, project_dir)?;
    if state.status != SessionStatus::LeaderlessDegraded {
        return Err(CliErrorKind::session_agent_conflict(
            "leader recovery is only valid for leaderless_degraded sessions".to_string(),
        )
        .into());
    }

    let expected_preset = state
        .policy
        .degraded_recovery
        .preset_id
        .as_deref()
        .ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(
                "session does not allow preset-managed leader recovery".to_string(),
            ))
        })?;
    if expected_preset != preset {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "session requires recovery preset '{expected_preset}', got '{preset}'"
        ))
        .into());
    }

    Ok(AgentTuiStartRequest {
        runtime: runtime_name.to_string(),
        role: SessionRole::Leader,
        fallback_role: None,
        capabilities: vec![format!("policy-preset:{preset}")],
        name: Some(format!("Recovered {runtime_name}")),
        prompt: None,
        project_dir: Some(project_dir.to_string_lossy().into_owned()),
        argv: Vec::new(),
        rows: 30,
        cols: 120,
        persona: None,
    })
}

/// List sessions for a project.
///
/// # Errors
/// Returns `CliError` on storage failures.
pub fn list_sessions(project_dir: &Path, include_all: bool) -> Result<Vec<SessionState>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let summaries = client.list_sessions()?;
        let mut sessions: Vec<SessionState> = summaries
            .into_iter()
            .filter(|summary| include_all || summary.status == SessionStatus::Active)
            .map(|summary| summary_to_session_state(&summary))
            .collect();
        sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        return Ok(sessions);
    }

    let session_ids = if include_all {
        storage::list_known_session_ids(project_dir)?
    } else {
        storage::load_active_registry_for(project_dir)
            .sessions
            .into_keys()
            .collect()
    };

    let mut sessions = Vec::new();
    for session_id in session_ids {
        if let Some(mut state) = storage::load_state(project_dir, &session_id)? {
            state.metrics = SessionMetrics::recalculate(&state);
            sessions.push(state);
        }
    }
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(sessions)
}

/// List sessions across all known project contexts.
///
/// Uses daemon index discovery to find sessions regardless of which project
/// directory the caller is running from.
///
/// # Errors
/// Returns `CliError` on discovery failures.
pub fn list_sessions_global(include_all: bool) -> Result<Vec<SessionState>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let summaries = client.list_sessions()?;
        let mut sessions: Vec<SessionState> = summaries
            .into_iter()
            .filter(|summary| include_all || summary.status == SessionStatus::Active)
            .map(|summary| summary_to_session_state(&summary))
            .collect();
        sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        return Ok(sessions);
    }

    let resolved = daemon_index::discover_sessions(include_all)?;
    let mut sessions: Vec<SessionState> = resolved
        .into_iter()
        .map(|entry| {
            let mut state = entry.state;
            state.metrics = SessionMetrics::recalculate(&state);
            state
        })
        .collect();
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(sessions)
}

/// Resolve the effective project directory for a session command.
///
/// Checks the local project directory first (fast path). If the session is
/// not found there, searches across all project contexts using the daemon
/// index. Returns `context_root` when the original project directory is
/// unavailable - this works because `project_context_dir` is idempotent
/// for paths already under the projects root.
///
/// # Errors
/// Returns `CliError` if the session cannot be found in any project.
pub fn resolve_session_project_dir(
    session_id: &str,
    local_project_dir: &Path,
) -> Result<PathBuf, CliError> {
    if storage::load_state(local_project_dir, session_id)?.is_some() {
        return Ok(local_project_dir.to_path_buf());
    }
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        return Ok(detail
            .session
            .project_dir
            .map_or_else(|| PathBuf::from(detail.session.context_root), PathBuf::from));
    }
    let resolved = daemon_index::resolve_session(session_id)?;
    Ok(resolved
        .project
        .project_dir
        .unwrap_or(resolved.project.context_root))
}
