use std::path::Path;

use harness_daemon_client::DaemonClient;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_kernel::io::validate_safe_segment;
use harness_session::service::{
    cancel_signal_local, daemon_client_error, list_signals_local, send_signal_local,
};
use harness_session::types::SessionSignalRecord;
use harness_session::wire;
use tokio::runtime::Handle;

/// Send a file-backed signal to a running agent session, dialing a live
/// daemon first when one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target agent is not
/// active, or the runtime adapter is unknown.
pub fn send_signal(
    session_id: &str,
    agent_id: &str,
    command: &str,
    message: &str,
    action_hint: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<SessionSignalRecord, CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        let request = wire::SignalSendRequest {
            actor: actor_id.to_string(),
            agent_id: agent_id.to_string(),
            command: command.to_string(),
            message: message.to_string(),
            action_hint: action_hint.map(ToString::to_string),
        };
        let detail: wire::SessionDetail = client
            .post(&format!("/v1/sessions/{session_id}/signal"), &request)
            .map_err(|error| daemon_client_error("send signal", &error))?;
        return detail
            .signals
            .into_iter()
            .find(|signal| signal.signal.command == command && signal.agent_id == agent_id)
            .ok_or_else(|| {
                CliErrorKind::workflow_io(
                    "daemon sent signal but returned no matching signal record",
                )
                .into()
            });
    }

    send_signal_local(
        session_id,
        agent_id,
        command,
        message,
        action_hint,
        actor_id,
        project_dir,
    )
}

/// Cancel a pending signal by writing a rejected acknowledgment and moving
/// the signal file out of pending, dialing a live daemon first when one is
/// reachable.
///
/// # Errors
/// Returns `CliError` when the session/agent cannot be resolved, the signal
/// file cannot be found, or ack persistence fails.
pub fn cancel_signal(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        let request = wire::SignalCancelRequest {
            actor: actor_id.to_string(),
            agent_id: agent_id.to_string(),
            signal_id: signal_id.to_string(),
        };
        let _: wire::SessionDetail = client
            .post(
                &format!("/v1/sessions/{session_id}/signal-cancel"),
                &request,
            )
            .map_err(|error| daemon_client_error("cancel signal", &error))?;
        return Ok(());
    }

    cancel_signal_local(session_id, agent_id, signal_id, actor_id, project_dir)
}

/// List all signals for a session, optionally narrowed to one agent,
/// dialing a live daemon first when one is reachable.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or runtime signal
/// directories cannot be read.
pub fn list_signals(
    session_id: &str,
    agent_filter: Option<&str>,
    project_dir: &Path,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        validate_safe_segment(session_id)?;
        let detail: wire::SessionDetail = client
            .get(&format!("/v1/sessions/{session_id}"), &[])
            .map_err(|error| daemon_client_error("get session detail", &error))?;
        let mut signals: Vec<SessionSignalRecord> = detail
            .signals
            .into_iter()
            .filter(|signal| agent_filter.is_none_or(|filter| signal.agent_id == filter))
            .collect();
        signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
        return Ok(signals);
    }

    list_signals_local(session_id, agent_filter, project_dir)
}
