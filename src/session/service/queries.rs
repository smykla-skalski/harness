use std::path::Path;

use harness_daemon_client::DaemonClient;
use harness_kernel::errors::CliError;
use harness_session::service::{
    daemon_client_error, list_sessions_global_local, list_sessions_local, summary_to_session_state,
};
use harness_session::types::SessionState;
use harness_session::wire;

/// List sessions for a project, dialing a live daemon first when one is
/// reachable.
///
/// # Errors
/// Returns `CliError` on storage failures.
pub fn list_sessions(project_dir: &Path, include_all: bool) -> Result<Vec<SessionState>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let summaries: Vec<wire::SessionSummary> = client
            .get("/v1/sessions", &[])
            .map_err(|error| daemon_client_error("list sessions", &error))?;
        let mut sessions: Vec<SessionState> = summaries
            .into_iter()
            .filter(|summary| include_all || summary.status.is_default_visible())
            .map(|summary| summary_to_session_state(&summary))
            .collect();
        sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        return Ok(sessions);
    }

    list_sessions_local(project_dir, include_all)
}

/// List sessions across all known project contexts, dialing a live daemon
/// first when one is reachable.
///
/// # Errors
/// Returns `CliError` on discovery failures.
pub fn list_sessions_global(include_all: bool) -> Result<Vec<SessionState>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let summaries: Vec<wire::SessionSummary> = client
            .get("/v1/sessions", &[])
            .map_err(|error| daemon_client_error("list sessions", &error))?;
        let mut sessions: Vec<SessionState> = summaries
            .into_iter()
            .filter(|summary| include_all || summary.status.is_default_visible())
            .map(|summary| summary_to_session_state(&summary))
            .collect();
        sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        return Ok(sessions);
    }

    list_sessions_global_local(include_all)
}
