use std::path::Path;

use harness_daemon_client::DaemonClient;
use harness_kernel::errors::CliError;
use harness_kernel::io::validate_safe_segment;
use harness_session::service::{
    assign_role_local, daemon_client_error, end_session_local, remove_agent_local,
    transfer_leader_local, update_session_title_local,
};
use harness_session::types::{SessionRole, SessionState};
use harness_session::wire;
use tokio::runtime::Handle;

// `start_session`, `start_session_with_policy`, `join_session`, and
// `join_session_with_fallback` are NOT wrapped here: they keep their former
// fused shape in `harness_session::service` (see that module's doc comments)
// because `daemon::service::direct`'s own no-local-database fallback needs
// the real dial-or-local decision and reaches them directly, with no path
// through this crate. They reach CLI callers unchanged through the blanket
// `pub use harness_session::service::*;` in `mod.rs`.

/// End a session that has not already ended (leader or control plane only),
/// dialing a live daemon first when one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, workers have active tasks,
/// or on storage failures.
pub fn end_session(session_id: &str, actor_id: &str, project_dir: &Path) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        let request = wire::SessionEndRequest {
            actor: actor_id.to_string(),
        };
        let _: wire::SessionDetail = client
            .post(&format!("/v1/sessions/{session_id}/end"), &request)
            .map_err(|error| daemon_client_error("end session", &error))?;
        return Ok(());
    }

    end_session_local(session_id, actor_id, project_dir)
}

/// Assign or change the role of an agent (leader only), dialing a live
/// daemon first when one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the agent is not found.
pub fn assign_role(
    session_id: &str,
    agent_id: &str,
    role: SessionRole,
    reason: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        validate_safe_segment(agent_id)?;
        let request = wire::RoleChangeRequest {
            actor: actor_id.to_string(),
            role,
            reason: reason.map(ToString::to_string),
        };
        let url = format!("/v1/sessions/{session_id}/agents/{agent_id}/role");
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("assign role", &error))?;
        return Ok(());
    }

    assign_role_local(session_id, agent_id, role, reason, actor_id, project_dir)
}

/// Remove an agent from a session (leader only), dialing a live daemon
/// first when one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the agent is not found.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        validate_safe_segment(agent_id)?;
        let request = wire::AgentRemoveRequest {
            actor: actor_id.to_string(),
        };
        let url = format!("/v1/sessions/{session_id}/agents/{agent_id}/remove");
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("remove agent", &error))?;
        return Ok(());
    }

    remove_agent_local(session_id, agent_id, actor_id, project_dir)
}

/// Transfer leadership to another agent, dialing a live daemon first when
/// one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the target is not found.
pub fn transfer_leader(
    session_id: &str,
    new_leader_id: &str,
    reason: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        let request = wire::LeaderTransferRequest {
            actor: actor_id.to_string(),
            new_leader_id: new_leader_id.to_string(),
            reason: reason.map(ToString::to_string),
        };
        let _: wire::SessionDetail = client
            .post(&format!("/v1/sessions/{session_id}/leader"), &request)
            .map_err(|error| daemon_client_error("transfer leader", &error))?;
        return Ok(());
    }

    transfer_leader_local(session_id, new_leader_id, reason, actor_id, project_dir)
}

/// Update a session title, dialing a live daemon first when one is
/// reachable.
///
/// # Errors
/// Returns `CliError` if the session cannot be found or persisted.
pub fn update_session_title(
    session_id: &str,
    title: &str,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        validate_safe_segment(session_id)?;
        let request = wire::SessionTitleRequest {
            title: title.to_string(),
        };
        let response: wire::SessionMutationResponse = client
            .post(&format!("/v1/sessions/{session_id}/title"), &request)
            .map_err(|error| daemon_client_error("update session title", &error))?;
        return Ok(response.state);
    }

    update_session_title_local(session_id, title, project_dir)
}
