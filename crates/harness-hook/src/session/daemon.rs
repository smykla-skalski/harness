use std::path::Path;

use harness_daemon_client::{ClientError, DaemonClient};
use harness_protocol::agent::AckResult;
use harness_protocol::session::AgentRegistration;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::service::ResolvedRuntimeSessionAgent;

#[derive(Debug, Deserialize)]
struct RuntimeSessionResolutionResponse {
    resolved: Option<ResolvedRuntimeSessionAgent>,
}

#[derive(Debug, Serialize)]
struct SignalAckRequest<'a> {
    agent_id: &'a str,
    signal_id: &'a str,
    result: AckResult,
    project_dir: String,
}

#[derive(Debug, Serialize)]
struct SessionLeaveRequest<'a> {
    agent_id: &'a str,
}

#[derive(Debug, Serialize)]
struct RuntimeSessionRegistrationRequest<'a> {
    managed_agent_id: &'a str,
    runtime: &'a str,
    runtime_session_id: &'a str,
    project_dir: String,
}

#[derive(Debug, Deserialize)]
struct RuntimeSessionRegistrationResponse {
    registered: bool,
}

#[derive(Debug, Deserialize)]
struct SessionAgentResponse {
    agents: Vec<AgentRegistration>,
}

pub(super) fn resolve_runtime_session(
    runtime_name: &str,
    runtime_session_id: &str,
) -> Option<Result<Option<ResolvedRuntimeSessionAgent>, CliError>> {
    let client = DaemonClient::try_connect()?;
    Some(
        client
            .get_optional::<RuntimeSessionResolutionResponse>(
                "/v1/runtime-sessions/resolve",
                &[
                    ("runtime_name", runtime_name),
                    ("runtime_session_id", runtime_session_id),
                ],
            )
            .map_err(|error| map_error("resolve runtime session", &error))
            .and_then(|response| {
                response.map(|payload| payload.resolved).ok_or_else(|| {
                    CliErrorKind::session_agent_conflict(
                        "daemon does not support /v1/runtime-sessions/resolve; upgrade the daemon"
                            .to_string(),
                    )
                    .into()
                })
            }),
    )
}

pub(super) fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
) -> Option<Result<(), CliError>> {
    let client = DaemonClient::try_connect()?;
    let request = SignalAckRequest {
        agent_id,
        signal_id,
        result,
        project_dir: project_dir.to_string_lossy().into_owned(),
    };
    Some(
        client
            .post::<_, serde_json::Value>(
                &format!("/v1/sessions/{session_id}/signal-ack"),
                &request,
            )
            .map(|_| ())
            .map_err(|error| map_error("record signal acknowledgment", &error)),
    )
}

pub(super) fn leave_session(session_id: &str, agent_id: &str) -> Option<Result<(), CliError>> {
    let client = DaemonClient::try_connect()?;
    Some(
        client
            .post::<_, serde_json::Value>(
                &format!("/v1/sessions/{session_id}/leave"),
                &SessionLeaveRequest { agent_id },
            )
            .map(|_| ())
            .map_err(|error| map_error("leave session", &error)),
    )
}

pub(super) fn register_runtime_session(
    session_id: &str,
    runtime_name: &str,
    managed_agent_id: &str,
    runtime_session_id: &str,
    project_dir: &Path,
) -> Option<Result<bool, CliError>> {
    let client = DaemonClient::try_connect()?;
    let request = RuntimeSessionRegistrationRequest {
        managed_agent_id,
        runtime: runtime_name,
        runtime_session_id,
        project_dir: project_dir.to_string_lossy().into_owned(),
    };
    Some(
        client
            .post::<_, RuntimeSessionRegistrationResponse>(
                &format!("/v1/sessions/{session_id}/runtime-session"),
                &request,
            )
            .map(|response| response.registered)
            .map_err(|error| map_error("register runtime session", &error)),
    )
}

pub(super) fn session_agent_is_alive(
    session_id: &str,
    agent_id: &str,
) -> Option<Result<bool, CliError>> {
    let client = DaemonClient::try_connect()?;
    Some(
        client
            .get::<SessionAgentResponse>(&format!("/v1/sessions/{session_id}"), &[])
            .map(|response| {
                response
                    .agents
                    .iter()
                    .find(|agent| agent.agent_id == agent_id)
                    .is_some_and(|agent| agent.status.is_alive())
            })
            .map_err(|error| map_error("load session agent", &error)),
    )
}

pub(crate) fn signal_managed_terminal_ready(
    managed_agent_id: &str,
) -> Option<Result<(), CliError>> {
    let client = DaemonClient::try_connect()?;
    Some(
        client
            .post::<_, serde_json::Value>(
                &format!("/v1/managed-agents/{managed_agent_id}/ready"),
                &serde_json::json!({}),
            )
            .map(|_| ())
            .map_err(|error| map_error("signal managed terminal readiness", &error)),
    )
}

fn map_error(operation: &str, error: &ClientError) -> CliError {
    CliErrorKind::workflow_io(format!("daemon {operation}: {error}")).into()
}
