//! ACP agent-side bridge entry point.
//!
//! Wires up the `Agent.builder()` from `agent_client_protocol`, registers
//! handlers for `initialize`, `session/new`, `session/prompt`, and the
//! `session/cancel` notification, then connects to stdio.
//!
//! The handlers share a [`SessionStore`] and an [`AgentConfig`] captured at
//! process start. The `session/prompt` turn loop runs in `cx.spawn` so the
//! ACP event loop keeps servicing other messages — most importantly the
//! `session/cancel` notification — while a turn is in flight.

use std::sync::Arc;
use uuid::Uuid;

use agent_client_protocol::schema::{
    AgentCapabilities, CancelNotification, Implementation, InitializeRequest, InitializeResponse,
    NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse, SessionId, StopReason,
};
use agent_client_protocol::util::internal_error;
use agent_client_protocol::{Agent, ConnectionTo, Dispatch, Stdio};

use crate::openrouter::{AgentConfig, ConfigError, OpenRouterClient};

use super::model_catalog::{DEFAULT_MODEL_ID, build_session_models};
use super::session::{SessionState, SessionStore};
use super::turn::drive_turn;

/// Run the ACP agent server on stdio until the client disconnects.
///
/// # Errors
/// Returns an error if the underlying ACP connection terminates abnormally
/// or the `OPENROUTER_API_KEY` environment variable is missing at startup.
pub async fn run_stdio() -> Result<(), agent_client_protocol::Error> {
    let store = SessionStore::new();
    let config = match AgentConfig::from_env() {
        Ok(config) => Arc::new(config),
        Err(error) => return Err(config_error(error)),
    };

    let store_new = store.clone();
    let config_new = config.clone();
    let store_prompt = store.clone();
    let config_prompt = config.clone();
    let store_cancel = store.clone();

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
            async move |request: NewSessionRequest, responder, _connection| {
                let response = handle_new_session(&store_new, &config_new, request).await;
                match response {
                    Ok(response) => responder.respond(response),
                    Err(error) => responder.respond_with_error(error),
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: PromptRequest, responder, connection| {
                let store = store_prompt.clone();
                let config = config_prompt.clone();
                connection.spawn({
                    let connection = connection.clone();
                    async move {
                        let stop_reason = run_prompt(&connection, &store, &config, request).await;
                        responder.respond(PromptResponse::new(stop_reason))
                    }
                })?;
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |notification: CancelNotification, _connection| {
                store_cancel.cancel(&notification.session_id).await;
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_dispatch(
            async move |message: Dispatch, connection: ConnectionTo<agent_client_protocol::Client>| {
                let method = message.method().to_owned();
                message.respond_with_error(
                    internal_error(format!(
                        "harness-openrouter-agent: method '{method}' not handled"
                    )),
                    connection,
                )
            },
            agent_client_protocol::on_receive_dispatch!(),
        )
        .connect_to(Stdio::new())
        .await
}

fn config_error(error: ConfigError) -> agent_client_protocol::Error {
    internal_error(format!("openrouter shim config error: {error}"))
}

fn initialize_response(request: InitializeRequest) -> InitializeResponse {
    InitializeResponse::new(request.protocol_version)
        .agent_capabilities(AgentCapabilities::new())
        .agent_info(Some(Implementation::new(
            "harness-openrouter-agent",
            env!("CARGO_PKG_VERSION"),
        )))
}

async fn run_prompt(
    connection: &ConnectionTo<agent_client_protocol::Client>,
    store: &SessionStore,
    config: &AgentConfig,
    request: PromptRequest,
) -> StopReason {
    let client = match OpenRouterClient::new(
        config.base_url.clone(),
        config.api_key.clone(),
        config.http_referer.clone(),
        config.x_title.clone(),
    ) {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!(%error, "failed to build OpenRouter client for prompt");
            return StopReason::EndTurn;
        }
    };
    drive_turn(connection, &client, store, &request.session_id, request.prompt).await
}

async fn handle_new_session(
    store: &SessionStore,
    config: &AgentConfig,
    request: NewSessionRequest,
) -> Result<NewSessionResponse, agent_client_protocol::Error> {
    let session_id = SessionId::new(Uuid::new_v4().to_string());
    let client = OpenRouterClient::new(
        config.base_url.clone(),
        config.api_key.clone(),
        config.http_referer.clone(),
        config.x_title.clone(),
    )
    .map_err(|error| internal_error(format!("failed to build OpenRouter client: {error}")))?;

    let model_state = build_session_models(&client, DEFAULT_MODEL_ID).await;
    let selected_model = model_state.current_model_id.0.as_ref().to_owned();

    store
        .insert(
            session_id.clone(),
            SessionState::new(request.cwd, selected_model),
        )
        .await;

    Ok(NewSessionResponse::new(session_id).models(Some(model_state)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::ProtocolVersion;
    use std::path::PathBuf;

    fn initialize_request() -> InitializeRequest {
        InitializeRequest::new(ProtocolVersion::LATEST)
    }

    fn test_config() -> AgentConfig {
        AgentConfig::from_source(|name| match name {
            "OPENROUTER_API_KEY" => Some("sk-test-not-used".to_owned()),
            "OPENROUTER_API_URL" => Some("http://127.0.0.1:0/api/v1".to_owned()),
            _ => None,
        })
        .expect("config")
    }

    #[test]
    fn initialize_response_carries_agent_info() {
        let response = initialize_response(initialize_request());
        let info = response.agent_info.expect("agent info");
        assert_eq!(info.name, "harness-openrouter-agent");
        assert_eq!(info.version, env!("CARGO_PKG_VERSION"));
    }

    #[tokio::test]
    async fn new_session_assigns_uuid_and_stores_state() {
        let store = SessionStore::new();
        let config = test_config();
        // base_url:0 means the list_models call fails fast; build_session_models
        // falls back to the curated list, so handle_new_session still succeeds.
        let request = NewSessionRequest::new(PathBuf::from("/tmp/proj"));
        let response = handle_new_session(&store, &config, request)
            .await
            .expect("new session");
        assert!(!response.session_id.0.as_ref().is_empty());
        let snapshot = store
            .snapshot(&response.session_id)
            .await
            .expect("session stored");
        assert_eq!(snapshot.project_dir, PathBuf::from("/tmp/proj"));
        assert_eq!(snapshot.model, DEFAULT_MODEL_ID);
        let models = response.models.expect("models");
        assert_eq!(models.current_model_id.0.as_ref(), DEFAULT_MODEL_ID);
        assert!(!models.available_models.is_empty());
    }
}
