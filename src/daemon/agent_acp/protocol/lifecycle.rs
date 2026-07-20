//! Capability-gated ACP session lifecycle calls.
//!
//! Every method here is optional in protocol v1, so each one checks the
//! capability the agent advertised during `initialize` before touching the
//! wire. Calling an unsupported method would earn a JSON-RPC method-not-found
//! from a well-behaved agent and undefined behavior from a sloppy one, so the
//! gate turns both into one predictable error.

use agent_client_protocol::schema::v1::{
    CloseSessionRequest, DeleteSessionRequest, ListSessionsRequest, SessionId, SessionInfo,
};
use agent_client_protocol::{Agent, ConnectionTo};

use super::commands::ProtocolCommandResult;
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::agent_acp::{AcpAgentHandshake, AcpSessionListPage, AcpSessionSummary};

pub(super) async fn list_sessions(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    request: ListSessionsRequest,
) -> ProtocolCommandResult<AcpSessionListPage> {
    require_capability(supervisor, "session.list", |handshake| {
        handshake.supports_session_list
    })?;
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/list"));
    let response = connection
        .send_request(request)
        .block_task()
        .await
        .map_err(|error| error.to_string())?;
    Ok(AcpSessionListPage {
        sessions: response.sessions.into_iter().map(session_summary).collect(),
        next_cursor: response.next_cursor,
    })
}

pub(super) async fn close_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
) -> ProtocolCommandResult<()> {
    require_capability(supervisor, "session.close", |handshake| {
        handshake.supports_session_close
    })?;
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/close"));
    connection
        .send_request(CloseSessionRequest::new(session_id))
        .block_task()
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

pub(super) async fn delete_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
) -> ProtocolCommandResult<()> {
    require_capability(supervisor, "session.delete", |handshake| {
        handshake.supports_session_delete
    })?;
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/delete"));
    connection
        .send_request(DeleteSessionRequest::new(session_id))
        .block_task()
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn require_capability(
    supervisor: &AcpSessionSupervisor,
    capability: &str,
    supported: impl Fn(&AcpAgentHandshake) -> bool,
) -> ProtocolCommandResult<()> {
    if supervisor
        .handshake()
        .is_some_and(|handshake| supported(handshake))
    {
        return Ok(());
    }
    Err(format!(
        "agent does not advertise the {capability} capability"
    ))
}

fn session_summary(info: SessionInfo) -> AcpSessionSummary {
    AcpSessionSummary {
        session_id: info.session_id.0.to_string(),
        cwd: info.cwd.to_string_lossy().into_owned(),
        additional_directories: info
            .additional_directories
            .iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect(),
        title: info.title,
        updated_at: info.updated_at,
    }
}
