use std::path::Path;

use crate::daemon::client::DaemonClient;
use crate::daemon::protocol;
use crate::errors::CliError;

use super::{apply_register_agent_runtime_session, ensure_known_runtime, storage, utc_now};

/// Register or refresh a managed agent's runtime session ID after join.
///
/// # Errors
/// Returns `CliError` on storage or daemon mutation failures.
pub fn register_agent_runtime_session(
    session_id: &str,
    runtime_name: &str,
    tui_id: &str,
    agent_session_id: &str,
    project_dir: &Path,
) -> Result<bool, CliError> {
    ensure_known_runtime(
        runtime_name,
        "runtime session registration requires a known runtime",
    )?;
    if let Some(client) = DaemonClient::try_connect() {
        return client.register_agent_runtime_session(
            session_id,
            &protocol::AgentRuntimeSessionRegistrationRequest {
                tui_id: tui_id.to_string(),
                runtime: runtime_name.to_string(),
                agent_session_id: agent_session_id.to_string(),
                project_dir: project_dir.to_string_lossy().into_owned(),
            },
        );
    }
    if storage::load_state(project_dir, session_id)?.is_none() {
        return Ok(false);
    }
    let now = utc_now();
    let mut registered = false;
    let _ = storage::update_state_if_changed(project_dir, session_id, |state| {
        registered = apply_register_agent_runtime_session(
            state,
            runtime_name,
            tui_id,
            agent_session_id,
            &now,
        )?;
        Ok(registered)
    })?;
    Ok(registered)
}
