//! Client-side half of the ACP `initialize` exchange: the capabilities
//! harness advertises and the agent-reported handshake summary it records.

use agent_client_protocol::schema::v1::{
    BooleanConfigOptionCapabilities, ClientCapabilities, ClientSessionCapabilities,
    FileSystemCapabilities, InitializeResponse, SessionConfigOptionsCapabilities,
};

use crate::daemon::agent_acp::AcpAgentHandshake;

pub(super) fn harness_client_capabilities() -> ClientCapabilities {
    ClientCapabilities::new()
        .fs(FileSystemCapabilities::new()
            .read_text_file(true)
            .write_text_file(true))
        .terminal(true)
        .session(ClientSessionCapabilities::new().config_options(
            SessionConfigOptionsCapabilities::new().boolean(BooleanConfigOptionCapabilities::new()),
        ))
}

pub(super) fn handshake_from_initialize(response: &InitializeResponse) -> AcpAgentHandshake {
    let capabilities = &response.agent_capabilities;
    let session = &capabilities.session_capabilities;
    AcpAgentHandshake {
        protocol_version: response.protocol_version.as_u16(),
        agent_name: response.agent_info.as_ref().map(|info| info.name.clone()),
        agent_version: response
            .agent_info
            .as_ref()
            .map(|info| info.version.clone()),
        agent_title: response
            .agent_info
            .as_ref()
            .and_then(|info| info.title.clone()),
        auth_method_ids: response
            .auth_methods
            .iter()
            .map(|method| method.id().0.to_string())
            .collect(),
        supports_load_session: capabilities.load_session,
        supports_session_list: session.list.is_some(),
        supports_session_resume: session.resume.is_some(),
        supports_session_close: session.close.is_some(),
        supports_session_delete: session.delete.is_some(),
        supports_additional_directories: session.additional_directories.is_some(),
        supports_logout: capabilities.auth.logout.is_some(),
    }
}

#[cfg(test)]
mod tests {
    use agent_client_protocol::schema::ProtocolVersion;
    use agent_client_protocol::schema::v1::{
        AgentAuthCapabilities, AgentCapabilities, AuthMethod, AuthMethodAgent, Implementation,
        LogoutCapabilities, SessionCapabilities, SessionCloseCapabilities,
        SessionDeleteCapabilities, SessionListCapabilities, SessionResumeCapabilities,
    };

    use super::*;

    #[test]
    fn handshake_captures_agent_info_capabilities_and_auth() {
        let response = InitializeResponse::new(ProtocolVersion::V1)
            .agent_info(Some(
                Implementation::new("codex-acp", "0.16.0").title("Codex".to_owned()),
            ))
            .agent_capabilities(
                AgentCapabilities::new()
                    .load_session(true)
                    .session_capabilities(
                        SessionCapabilities::new()
                            .list(SessionListCapabilities::new())
                            .resume(SessionResumeCapabilities::new())
                            .close(SessionCloseCapabilities::new())
                            .delete(SessionDeleteCapabilities::new()),
                    )
                    .auth(AgentAuthCapabilities::new().logout(LogoutCapabilities::new())),
            )
            .auth_methods(vec![AuthMethod::Agent(AuthMethodAgent::new(
                "oauth", "OAuth",
            ))]);

        let handshake = handshake_from_initialize(&response);

        assert_eq!(handshake.protocol_version, 1);
        assert_eq!(handshake.agent_name.as_deref(), Some("codex-acp"));
        assert_eq!(handshake.agent_version.as_deref(), Some("0.16.0"));
        assert_eq!(handshake.agent_title.as_deref(), Some("Codex"));
        assert_eq!(handshake.auth_method_ids, vec!["oauth".to_string()]);
        assert!(handshake.supports_load_session);
        assert!(handshake.supports_session_list);
        assert!(handshake.supports_session_resume);
        assert!(handshake.supports_session_close);
        assert!(handshake.supports_session_delete);
        assert!(!handshake.supports_additional_directories);
        assert!(handshake.supports_logout);
    }

    #[test]
    fn handshake_defaults_to_no_capabilities_for_minimal_agent() {
        let response = InitializeResponse::new(ProtocolVersion::V1);
        let handshake = handshake_from_initialize(&response);
        assert_eq!(handshake.protocol_version, 1);
        assert_eq!(handshake.agent_name, None);
        assert!(handshake.auth_method_ids.is_empty());
        assert!(!handshake.supports_load_session);
        assert!(!handshake.supports_session_list);
        assert!(!handshake.supports_logout);
    }
}
