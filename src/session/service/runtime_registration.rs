use std::path::Path;

use crate::daemon::client::DaemonClient;
use crate::daemon::protocol;
use crate::errors::CliError;
use crate::session::types::{HarnessSessionId, ManagedAgentId, ManagedAgentRef, RuntimeSessionId};

use super::{apply_register_agent_runtime_session, ensure_known_runtime, storage, utc_now};

/// Register or refresh a managed agent's runtime session ID after join.
///
/// # Errors
/// Returns `CliError` on storage or daemon mutation failures.
pub fn register_agent_runtime_session(
    session_id: &str,
    runtime_name: &str,
    tui_id: &str,
    runtime_session_id: &str,
    project_dir: &Path,
) -> Result<bool, CliError> {
    let session_id = HarnessSessionId::from(session_id);
    let managed_agent_id = ManagedAgentId::from(tui_id);
    let runtime_session_id = RuntimeSessionId::from(runtime_session_id);

    ensure_known_runtime(
        runtime_name,
        "runtime session registration requires a known runtime",
    )?;
    if let Some(client) = DaemonClient::try_connect() {
        return client.register_agent_runtime_session(
            session_id.as_str(),
            &protocol::AgentRuntimeSessionRegistrationRequest {
                tui_id: managed_agent_id.to_string(),
                runtime: runtime_name.to_string(),
                runtime_session_id: runtime_session_id.to_string(),
                project_dir: project_dir.to_string_lossy().into_owned(),
            },
        );
    }
    let layout = storage::layout_from_project_dir(project_dir, session_id.as_str())?;
    if storage::load_state(&layout)?.is_none() {
        return Ok(false);
    }
    let now = utc_now();
    let managed_agent = ManagedAgentRef::tui(managed_agent_id);
    let mut registered = false;
    let _ = storage::update_state_if_changed(&layout, |state| {
        registered = apply_register_agent_runtime_session(
            state,
            runtime_name,
            &managed_agent,
            runtime_session_id.as_str(),
            &now,
        )?;
        Ok(registered)
    })?;
    Ok(registered)
}
