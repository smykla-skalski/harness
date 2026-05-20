//! ACP agent-side bridge entry point.
//!
//! Wires up the `Agent.builder()` from `agent_client_protocol`, registers
//! handlers for the methods the harness daemon sends, and connects to stdio.
//!
//! Chunk 1 ships only the `initialize` handshake. `session/new` and
//! `session/prompt` reply with structured `not_yet_implemented` errors so the
//! daemon's supervision lifecycle can detect the shim and surface a clean
//! status during install verification while the streaming + tool-loop chunks
//! land.

use agent_client_protocol::schema::{
    AgentCapabilities, Implementation, InitializeRequest, InitializeResponse, NewSessionRequest,
    NewSessionResponse, PromptRequest, PromptResponse, SessionId, StopReason,
};
use agent_client_protocol::util::internal_error;
use agent_client_protocol::{Agent, ConnectionTo, Dispatch, Stdio};

/// Run the ACP agent server on stdio until the client disconnects.
///
/// # Errors
/// Returns an error if the underlying ACP connection terminates abnormally.
pub async fn run_stdio() -> Result<(), agent_client_protocol::Error> {
    Agent
        .builder()
        .name("harness-openrouter-agent")
        .on_receive_request(
            async move |request: InitializeRequest, responder, _connection| {
                responder.respond(initialize_response(request))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: NewSessionRequest, responder, _connection| {
                responder.respond(stub_new_session_response())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: PromptRequest, responder, _connection| {
                responder.respond(stub_prompt_response())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_dispatch(
            async move |message: Dispatch, connection: ConnectionTo<agent_client_protocol::Client>| {
                let method = message.method().to_owned();
                message.respond_with_error(
                    internal_error(format!(
                        "harness-openrouter-agent: method '{method}' not handled in this chunk"
                    )),
                    connection,
                )
            },
            agent_client_protocol::on_receive_dispatch!(),
        )
        .connect_to(Stdio::new())
        .await
}

fn initialize_response(request: InitializeRequest) -> InitializeResponse {
    InitializeResponse::new(request.protocol_version)
        .agent_capabilities(AgentCapabilities::new())
        .agent_info(Some(Implementation::new(
            "harness-openrouter-agent",
            env!("CARGO_PKG_VERSION"),
        )))
}

fn stub_new_session_response() -> NewSessionResponse {
    // Returning a real session id keeps the daemon happy during install
    // verification; the prompt handler still bails out so no traffic actually
    // exits this binary in chunk 1.
    NewSessionResponse::new(SessionId::new("openrouter-stub"))
}

fn stub_prompt_response() -> PromptResponse {
    PromptResponse::new(StopReason::Refusal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::ProtocolVersion;

    fn initialize_request() -> InitializeRequest {
        InitializeRequest::new(ProtocolVersion::LATEST)
    }

    #[test]
    fn initialize_response_carries_agent_info() {
        let response = initialize_response(initialize_request());
        let info = response.agent_info.expect("agent info");
        assert_eq!(info.name, "harness-openrouter-agent");
        assert_eq!(info.version, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn stub_new_session_returns_placeholder_id() {
        let response = stub_new_session_response();
        assert_eq!(response.session_id.0.as_ref(), "openrouter-stub");
    }

    #[test]
    fn stub_prompt_response_signals_refusal_until_next_chunk() {
        assert_eq!(stub_prompt_response().stop_reason, StopReason::Refusal);
    }
}

