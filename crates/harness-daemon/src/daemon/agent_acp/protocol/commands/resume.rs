use std::path::PathBuf;

use agent_client_protocol::schema::v1::SessionId;
use agent_client_protocol::{Agent, ConnectionTo};

use super::ProtocolCommandResult;
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::agent_acp::protocol::session_config::{
    AcpSessionRequestConfig, advertised_session_configuration,
    apply_requested_session_configuration,
};
use crate::daemon::agent_acp::protocol::session_guard::{RouteTarget, SessionRouteGuard};

#[expect(
    clippy::too_many_arguments,
    reason = "the protocol route and resume request require separate logical and provider identities"
)]
pub(super) async fn resume_protocol_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    acp_id: String,
    session_id: String,
    project_dir: PathBuf,
    session_config: &AcpSessionRequestConfig,
    resume_session_id: &str,
) -> ProtocolCommandResult<SessionId> {
    if !valid_resume_session_id(resume_session_id) {
        return Err("ACP exact session resume requires a non-empty normalized session id".into());
    }
    if !supervisor
        .handshake()
        .is_some_and(|handshake| handshake.supports_session_resume)
    {
        return Err("ACP agent does not support exact session resume".into());
    }
    let response = super::super::send_resume_session(
        supervisor,
        connection,
        project_dir,
        session_config,
        resume_session_id,
    )
    .await
    .map_err(|error| error.to_string())?;
    let protocol_session_id = SessionId::new(resume_session_id.to_string());
    session_guard.start_session(&protocol_session_id, RouteTarget { acp_id, session_id });
    if let Err(error) = apply_requested_session_configuration(
        supervisor,
        connection,
        &protocol_session_id,
        session_config,
        advertised_session_configuration(response.config_options.as_deref()),
    )
    .await
    {
        session_guard.stop_session(&protocol_session_id);
        return Err(error.to_string());
    }
    Ok(protocol_session_id)
}

fn valid_resume_session_id(session_id: &str) -> bool {
    !session_id.trim().is_empty() && session_id.trim() == session_id
}

#[cfg(test)]
mod tests {
    use super::valid_resume_session_id;

    #[test]
    fn exact_resume_session_id_must_be_nonempty_and_normalized() {
        assert!(valid_resume_session_id("openrouter-session-1"));
        assert!(!valid_resume_session_id(""));
        assert!(!valid_resume_session_id("  "));
        assert!(!valid_resume_session_id(" openrouter-session-1"));
        assert!(!valid_resume_session_id("openrouter-session-1\n"));
    }
}
