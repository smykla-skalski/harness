use std::path::Path;

use crate::infra::io::validate_safe_segment;
use crate::session::types::{HarnessSessionId, ManagedAgentId, ManagedAgentRef, RuntimeSessionId};
use crate::session::wire;
use harness_daemon_client::DaemonClient;
use harness_kernel::errors::{CliError, CliErrorKind};
use tokio::runtime::Handle;

use super::{apply_register_agent_runtime_session, ensure_known_runtime, storage, utc_now};

/// Register or refresh a managed agent's runtime session ID after join.
///
/// # Errors
/// Returns `CliError` on storage or daemon mutation failures.
pub fn register_agent_runtime_session(
    session_id: &str,
    runtime_name: &str,
    managed_agent_id: &str,
    runtime_session_id: &str,
    project_dir: &Path,
) -> Result<bool, CliError> {
    let session_id = HarnessSessionId::from(session_id);
    let managed_agent_id = ManagedAgentId::from(managed_agent_id);
    let runtime_session_id = RuntimeSessionId::from(runtime_session_id);

    ensure_known_runtime(
        runtime_name,
        "runtime session registration requires a known runtime",
    )?;
    // The leaf `harness-daemon-client` (already used by `harness-hook` for the
    // same registration call) keeps this domain code from depending on the
    // root crate's typed `daemon::client` facade; the wire types are already
    // domain-owned, so the generic client needs nothing daemon-shaped from us.
    //
    // The tokio-runtime check mirrors a guard the root facade's client enforced
    // internally: this call can run on the daemon's own async worker threads,
    // through `register_agent_runtime_session_direct`'s no-database fallback,
    // and a blocking round trip back to that same process would hold a worker
    // thread open with nothing to free it until the request times out.
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id.as_str())?;
        let request = wire::AgentRuntimeSessionRegistrationRequest {
            managed_agent_id: managed_agent_id.to_string(),
            runtime: runtime_name.to_string(),
            runtime_session_id: runtime_session_id.to_string(),
            project_dir: project_dir.to_string_lossy().into_owned(),
        };
        let response: wire::AgentRuntimeSessionRegistrationResponse = client
            .post(
                &format!("/v1/sessions/{}/runtime-session", session_id.as_str()),
                &request,
            )
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "daemon register runtime session: {error}"
                )))
            })?;
        return Ok(response.registered);
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
