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

use std::path::PathBuf;
use std::sync::Arc;
use uuid::Uuid;

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, Implementation, InitializeRequest, InitializeResponse,
    NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse, SessionId,
    SetSessionConfigOptionRequest, SetSessionConfigOptionResponse, StopReason,
};
use agent_client_protocol::util::internal_error;
use agent_client_protocol::{Agent, ConnectionTo, Dispatch, Stdio};

use crate::openrouter::{AgentConfig, ConfigError, OpenRouterClient, discard_api_key_file};

use super::model_catalog::{
    DEFAULT_MODEL_ID, MODEL_CONFIG_OPTION_ID, build_model_config_option,
};
use super::session::{SessionState, SessionStore};
use super::turn::drive_turn;

/// Run the ACP agent server on stdio until the client disconnects. The
/// daemon-supplied `api_key_file` carries the OpenRouter API key (Monitor →
/// keychain → daemon in-memory → daemon-written tempfile). The file is
/// unlinked immediately after the key is read, so it never lingers past
/// startup. A `None` value is rejected — the shim refuses to run without a
/// credential.
///
/// # Errors
/// Returns an error if the underlying ACP connection terminates abnormally
/// or the `api_key_file` is missing, unreadable, or empty.
pub async fn run_stdio(
    api_key_file: Option<PathBuf>,
) -> Result<(), agent_client_protocol::Error> {
    let store = SessionStore::new();
    let path = api_key_file.ok_or_else(|| config_error(ConfigError::MissingApiKeyFile))?;
    let config = match AgentConfig::from_api_key_file(&path) {
        Ok(config) => Arc::new(config),
        Err(error) => {
            discard_api_key_file(&path);
            return Err(config_error(error));
        }
    };
    discard_api_key_file(&path);

    let store_new = store.clone();
    let config_new = config.clone();
    let store_config = store.clone();
    let config_config = config.clone();
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
            async move |request: SetSessionConfigOptionRequest, responder, _connection| {
                let response =
                    handle_set_config_option(&store_config, &config_config, request).await;
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

    let model_option = build_model_config_option(&client, DEFAULT_MODEL_ID).await;

    store
        .insert(
            session_id.clone(),
            SessionState::new(request.cwd, DEFAULT_MODEL_ID.to_owned()),
        )
        .await;

    Ok(NewSessionResponse::new(session_id).config_options(vec![model_option]))
}

async fn handle_set_config_option(
    store: &SessionStore,
    config: &AgentConfig,
    request: SetSessionConfigOptionRequest,
) -> Result<SetSessionConfigOptionResponse, agent_client_protocol::Error> {
    if request.config_id.0.as_ref() != MODEL_CONFIG_OPTION_ID {
        return Err(internal_error(format!(
            "unknown session config option '{}'",
            request.config_id.0
        )));
    }
    let Some(model) = request.value.as_value_id() else {
        return Err(internal_error("model config option expects a select value"));
    };
    let model = model.0.to_string();
    if !store.set_model(&request.session_id, &model).await {
        return Err(internal_error(format!(
            "unknown ACP session '{}'",
            request.session_id.0
        )));
    }
    let client = OpenRouterClient::new(
        config.base_url.clone(),
        config.api_key.clone(),
        config.http_referer.clone(),
        config.x_title.clone(),
    )
    .map_err(|error| internal_error(format!("failed to build OpenRouter client: {error}")))?;
    let option = build_model_config_option(&client, &model).await;
    Ok(SetSessionConfigOptionResponse::new(vec![option]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::ProtocolVersion;
    use agent_client_protocol::schema::v1::{
        SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory,
        SessionConfigSelectOptions,
    };
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

    fn model_option_state(option: &SessionConfigOption) -> (String, usize) {
        let SessionConfigKind::Select(select) = &option.kind else {
            panic!("model option must be a select, got {:?}", option.kind);
        };
        let SessionConfigSelectOptions::Ungrouped(choices) = &select.options else {
            panic!("model options must be ungrouped");
        };
        (select.current_value.0.to_string(), choices.len())
    }

    #[tokio::test]
    async fn new_session_assigns_uuid_and_stores_state() {
        let store = SessionStore::new();
        let config = test_config();
        // base_url:0 fails the live model fetch fast; the curated fallback
        // keeps handle_new_session successful.
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
        let options = response.config_options.expect("config options");
        let option = options.first().expect("model option");
        assert_eq!(option.id.0.as_ref(), MODEL_CONFIG_OPTION_ID);
        assert_eq!(option.category, Some(SessionConfigOptionCategory::Model));
        let (current, choice_count) = model_option_state(option);
        assert_eq!(current, DEFAULT_MODEL_ID);
        assert!(choice_count > 0);
    }

    #[tokio::test]
    async fn set_config_option_updates_model_and_returns_snapshot() {
        let store = SessionStore::new();
        let config = test_config();
        let request = NewSessionRequest::new(PathBuf::from("/tmp/proj"));
        let response = handle_new_session(&store, &config, request)
            .await
            .expect("new session");
        let session_id = response.session_id.clone();

        let set = SetSessionConfigOptionRequest::new(
            session_id.clone(),
            MODEL_CONFIG_OPTION_ID,
            "anthropic/claude-haiku-4-5",
        );
        let snapshot_response = handle_set_config_option(&store, &config, set)
            .await
            .expect("set model");

        let stored = store.snapshot(&session_id).await.expect("session stored");
        assert_eq!(stored.model, "anthropic/claude-haiku-4-5");
        let option = snapshot_response
            .config_options
            .first()
            .expect("model option");
        let (current, _) = model_option_state(option);
        assert_eq!(current, "anthropic/claude-haiku-4-5");
    }

    #[tokio::test]
    async fn set_config_option_rejects_unknown_option_and_session() {
        let store = SessionStore::new();
        let config = test_config();
        let request = NewSessionRequest::new(PathBuf::from("/tmp/proj"));
        let response = handle_new_session(&store, &config, request)
            .await
            .expect("new session");

        let unknown_option = SetSessionConfigOptionRequest::new(
            response.session_id.clone(),
            "sampling",
            "anthropic/claude-haiku-4-5",
        );
        handle_set_config_option(&store, &config, unknown_option)
            .await
            .expect_err("unknown option id must be rejected");

        let unknown_session = SetSessionConfigOptionRequest::new(
            SessionId::new("missing-session"),
            MODEL_CONFIG_OPTION_ID,
            "anthropic/claude-haiku-4-5",
        );
        handle_set_config_option(&store, &config, unknown_session)
            .await
            .expect_err("unknown session must be rejected");
    }
}
