//! ACP agent-side bridge entry point.
//!
//! Wires up the `Agent.builder()` from `agent_client_protocol`, registers
//! handlers for `initialize`, `session/new`, `session/resume`,
//! `session/set_config_option`, `session/prompt`, and the `session/cancel`
//! notification, then connects to stdio.
//!
//! The handlers share a [`SessionStore`] and an [`OpenRouterClient`] built at
//! process start. The `session/prompt` turn loop runs in `cx.spawn` so the
//! ACP event loop keeps servicing other messages — most importantly the
//! `session/cancel` notification — while a turn is in flight.

use std::path::PathBuf;
use uuid::Uuid;

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, Implementation, InitializeRequest, InitializeResponse,
    NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse, ResumeSessionRequest,
    ResumeSessionResponse, SessionCapabilities, SessionConfigOption, SessionConfigSelectOption,
    SessionConfigSelectOptions, SessionId, SessionResumeCapabilities,
    SetSessionConfigOptionRequest, SetSessionConfigOptionResponse,
};
use agent_client_protocol::util::internal_error;
use agent_client_protocol::{Agent, ConnectionTo, Dispatch, Stdio};

use crate::openrouter::{AgentConfig, ConfigError, OpenRouterClient, discard_api_key_file};

use super::model_catalog::{DEFAULT_MODEL_ID, MODEL_CONFIG_OPTION_ID, build_model_config_option};
use super::session::{SessionState, SessionStore};
use super::turn::drive_turn;

const CAPABILITY_PROFILE_CONFIG_OPTION_ID: &str = "harness_capability_profile";
const STANDARD_CAPABILITY_PROFILE: &str = "standard";
const REPORT_ONLY_CAPABILITY_PROFILE: &str = "report_only";

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
pub async fn run_stdio(api_key_file: Option<PathBuf>) -> Result<(), agent_client_protocol::Error> {
    let store = SessionStore::new();
    let path = api_key_file.ok_or_else(|| config_error(ConfigError::MissingApiKeyFile))?;
    let config = match AgentConfig::from_api_key_file(&path) {
        Ok(config) => config,
        Err(error) => {
            discard_api_key_file(&path);
            return Err(config_error(error));
        }
    };
    discard_api_key_file(&path);
    let client = build_client(config)?;

    let store_new = store.clone();
    let client_new = client.clone();
    let store_config = store.clone();
    let client_config = client.clone();
    let store_resume = store.clone();
    let client_resume = client.clone();
    let store_prompt = store.clone();
    let client_prompt = client;
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
                let response = handle_new_session(&store_new, &client_new, request).await;
                responder.respond(response)
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: ResumeSessionRequest, responder, _connection| {
                let response = handle_resume_session(&store_resume, &client_resume, request).await;
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
                    handle_set_config_option(&store_config, &client_config, request).await;
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
                let client = client_prompt.clone();
                connection.spawn({
                    let connection = connection.clone();
                    async move {
                        let outcome = drive_turn(
                            &connection,
                            &client,
                            &store,
                            &request.session_id,
                            request.prompt,
                        )
                        .await;
                        match outcome {
                            Ok(stop_reason) => responder.respond(PromptResponse::new(stop_reason)),
                            Err(error) => responder.respond_with_error(error),
                        }
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
            async move |message: Dispatch,
                        _connection: ConnectionTo<agent_client_protocol::Client>| {
                let method = message.method().to_owned();
                match message {
                    Dispatch::Request(_, responder) => {
                        responder.respond_with_error(internal_error(format!(
                            "harness-openrouter-agent: method '{method}' not handled"
                        )))
                    }
                    Dispatch::Notification(_) | Dispatch::Response(_, _) => Ok(()),
                }
            },
            agent_client_protocol::on_receive_dispatch!(),
        )
        .connect_to(Stdio::new())
        .await
}

fn config_error(error: ConfigError) -> agent_client_protocol::Error {
    internal_error(format!("openrouter shim config error: {error}"))
}

fn build_client(config: AgentConfig) -> Result<OpenRouterClient, agent_client_protocol::Error> {
    OpenRouterClient::new(
        config.base_url,
        config.api_key,
        config.http_referer,
        config.x_title,
    )
    .map_err(|error| internal_error(format!("failed to build OpenRouter client: {error}")))
}

fn initialize_response(request: InitializeRequest) -> InitializeResponse {
    InitializeResponse::new(request.protocol_version)
        .agent_capabilities(AgentCapabilities::new().session_capabilities(
            SessionCapabilities::new().resume(SessionResumeCapabilities::new()),
        ))
        .agent_info(Some(Implementation::new(
            "harness-openrouter-agent",
            env!("CARGO_PKG_VERSION"),
        )))
}

async fn handle_new_session(
    store: &SessionStore,
    client: &OpenRouterClient,
    request: NewSessionRequest,
) -> NewSessionResponse {
    let session_id = SessionId::new(Uuid::new_v4().to_string());
    let model_option = build_model_config_option(client, DEFAULT_MODEL_ID).await;

    store
        .insert(
            session_id.clone(),
            SessionState::new(request.cwd, DEFAULT_MODEL_ID.to_owned()),
        )
        .await;

    NewSessionResponse::new(session_id)
        .config_options(vec![model_option, capability_profile_option(false)])
}

async fn handle_resume_session(
    store: &SessionStore,
    client: &OpenRouterClient,
    request: ResumeSessionRequest,
) -> Result<ResumeSessionResponse, agent_client_protocol::Error> {
    let snapshot = store
        .snapshot(&request.session_id)
        .await
        .ok_or_else(|| internal_error(format!("unknown ACP session '{}'", request.session_id.0)))?;
    if snapshot.project_dir != request.cwd {
        return Err(internal_error(format!(
            "ACP session '{}' belongs to a different working directory",
            request.session_id.0
        )));
    }
    let model_option = build_model_config_option(client, &snapshot.model).await;
    Ok(ResumeSessionResponse::new().config_options(vec![
        model_option,
        capability_profile_option(snapshot.report_only_review),
    ]))
}

async fn handle_set_config_option(
    store: &SessionStore,
    client: &OpenRouterClient,
    request: SetSessionConfigOptionRequest,
) -> Result<SetSessionConfigOptionResponse, agent_client_protocol::Error> {
    if request.config_id.0.as_ref() == CAPABILITY_PROFILE_CONFIG_OPTION_ID {
        let Some(profile) = request.value.as_value_id() else {
            return Err(internal_error(
                "capability profile config option expects a select value",
            ));
        };
        let report_only = match profile.0.as_ref() {
            STANDARD_CAPABILITY_PROFILE => false,
            REPORT_ONLY_CAPABILITY_PROFILE => true,
            value => {
                return Err(internal_error(format!(
                    "unknown capability profile '{value}'"
                )));
            }
        };
        if !store
            .set_report_only_review(&request.session_id, report_only)
            .await
        {
            return Err(internal_error(format!(
                "unknown ACP session '{}'",
                request.session_id.0
            )));
        }
        return Ok(SetSessionConfigOptionResponse::new(vec![
            capability_profile_option(report_only),
        ]));
    }
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
    let option = build_model_config_option(client, &model).await;
    Ok(SetSessionConfigOptionResponse::new(vec![option]))
}

fn capability_profile_option(report_only: bool) -> SessionConfigOption {
    SessionConfigOption::select(
        CAPABILITY_PROFILE_CONFIG_OPTION_ID,
        "Capability profile",
        if report_only {
            REPORT_ONLY_CAPABILITY_PROFILE
        } else {
            STANDARD_CAPABILITY_PROFILE
        },
        SessionConfigSelectOptions::Ungrouped(vec![
            SessionConfigSelectOption::new(STANDARD_CAPABILITY_PROFILE, "Standard"),
            SessionConfigSelectOption::new(REPORT_ONLY_CAPABILITY_PROFILE, "Report only"),
        ]),
    )
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

    fn test_client() -> OpenRouterClient {
        build_client(test_config()).expect("client")
    }

    #[test]
    fn initialize_response_carries_agent_info() {
        let response = initialize_response(initialize_request());
        let info = response.agent_info.expect("agent info");
        assert_eq!(info.name, "harness-openrouter-agent");
        assert_eq!(info.version, env!("CARGO_PKG_VERSION"));
        assert!(
            response
                .agent_capabilities
                .session_capabilities
                .resume
                .is_some()
        );
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
        let client = test_client();
        // base_url:0 fails the live model fetch fast; the curated fallback
        // keeps the model option populated.
        let request = NewSessionRequest::new(PathBuf::from("/tmp/proj"));
        let response = handle_new_session(&store, &client, request).await;
        assert!(!response.session_id.0.as_ref().is_empty());
        let snapshot = store
            .snapshot(&response.session_id)
            .await
            .expect("session stored");
        assert_eq!(snapshot.project_dir, PathBuf::from("/tmp/proj"));
        assert_eq!(snapshot.model, DEFAULT_MODEL_ID);
        let options = response.config_options.expect("config options");
        let option = options
            .iter()
            .find(|option| option.id.0.as_ref() == MODEL_CONFIG_OPTION_ID)
            .expect("model option");
        assert_eq!(option.category, Some(SessionConfigOptionCategory::Model));
        let (current, choice_count) = model_option_state(option);
        assert_eq!(current, DEFAULT_MODEL_ID);
        assert!(choice_count > 0);
        let capability = options
            .iter()
            .find(|option| option.id.0.as_ref() == CAPABILITY_PROFILE_CONFIG_OPTION_ID)
            .expect("capability profile option");
        let (current, _) = model_option_state(capability);
        assert_eq!(current, STANDARD_CAPABILITY_PROFILE);
    }

    #[tokio::test]
    async fn report_only_profile_is_durable_session_state() {
        let store = SessionStore::new();
        let client = test_client();
        let response = handle_new_session(
            &store,
            &client,
            NewSessionRequest::new(PathBuf::from("/tmp")),
        )
        .await;
        let set = SetSessionConfigOptionRequest::new(
            response.session_id.clone(),
            CAPABILITY_PROFILE_CONFIG_OPTION_ID,
            REPORT_ONLY_CAPABILITY_PROFILE,
        );
        handle_set_config_option(&store, &client, set)
            .await
            .expect("set report-only profile");
        assert!(
            store
                .snapshot(&response.session_id)
                .await
                .expect("session")
                .report_only_review
        );
    }

    #[tokio::test]
    async fn resume_session_reuses_existing_state_and_rejects_unknown_ids() {
        let store = SessionStore::new();
        let client = test_client();
        let response = handle_new_session(
            &store,
            &client,
            NewSessionRequest::new(PathBuf::from("/tmp/proj")),
        )
        .await;
        let session_id = response.session_id;

        handle_resume_session(
            &store,
            &client,
            ResumeSessionRequest::new(session_id.clone(), PathBuf::from("/tmp/proj")),
        )
        .await
        .expect("resume existing session");
        assert!(store.snapshot(&session_id).await.is_some());

        handle_resume_session(
            &store,
            &client,
            ResumeSessionRequest::new("missing-session", PathBuf::from("/tmp/proj")),
        )
        .await
        .expect_err("unknown session must fail");
    }

    #[tokio::test]
    async fn set_config_option_updates_model_and_returns_snapshot() {
        let store = SessionStore::new();
        let client = test_client();
        let request = NewSessionRequest::new(PathBuf::from("/tmp/proj"));
        let response = handle_new_session(&store, &client, request).await;
        let session_id = response.session_id.clone();

        let set = SetSessionConfigOptionRequest::new(
            session_id.clone(),
            MODEL_CONFIG_OPTION_ID,
            "anthropic/claude-haiku-4-5",
        );
        let snapshot_response = handle_set_config_option(&store, &client, set)
            .await
            .expect("set model");

        let stored = store.snapshot(&session_id).await.expect("session stored");
        assert_eq!(stored.model, "anthropic/claude-haiku-4-5");
        let option = snapshot_response
            .config_options
            .iter()
            .find(|option| option.id.0.as_ref() == MODEL_CONFIG_OPTION_ID)
            .expect("model option");
        let (current, _) = model_option_state(option);
        assert_eq!(current, "anthropic/claude-haiku-4-5");
    }

    #[tokio::test]
    async fn set_config_option_rejects_unknown_option_and_session() {
        let store = SessionStore::new();
        let client = test_client();
        let request = NewSessionRequest::new(PathBuf::from("/tmp/proj"));
        let response = handle_new_session(&store, &client, request).await;

        let unknown_option = SetSessionConfigOptionRequest::new(
            response.session_id.clone(),
            "sampling",
            "anthropic/claude-haiku-4-5",
        );
        handle_set_config_option(&store, &client, unknown_option)
            .await
            .expect_err("unknown option id must be rejected");

        let unknown_session = SetSessionConfigOptionRequest::new(
            SessionId::new("missing-session"),
            MODEL_CONFIG_OPTION_ID,
            "anthropic/claude-haiku-4-5",
        );
        handle_set_config_option(&store, &client, unknown_session)
            .await
            .expect_err("unknown session must be rejected");

        let stored = store
            .snapshot(&response.session_id)
            .await
            .expect("session stored");
        assert_eq!(stored.model, DEFAULT_MODEL_ID);
    }
}
