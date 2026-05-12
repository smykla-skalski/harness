use agent_client_protocol::schema::{
    NewSessionResponse, SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory,
    SessionConfigSelect, SessionConfigSelectGroup, SessionConfigSelectOption,
    SessionConfigSelectOptions, SessionConfigValueId, SessionId, SessionModelState,
    SetSessionConfigOptionRequest, SetSessionModelRequest,
};
use agent_client_protocol::{Agent, ConnectionTo, Error as AcpError, Result as AcpResult};

use crate::agents::acp::catalog::{
    AcpAgentDescriptor, AcpSessionConfigOptionBinding, AcpSessionConfiguration,
    AcpSessionEffortTransport, AcpSessionModelTransport,
};
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::agent_acp::manager::AcpAgentStartRequest;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::daemon::agent_acp) struct AcpSessionRequestConfig {
    model: Option<String>,
    effort: Option<String>,
    allow_custom_model: bool,
    session_configuration: AcpSessionConfiguration,
}

impl AcpSessionRequestConfig {
    pub(in crate::daemon::agent_acp) fn from_request(
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
    ) -> Self {
        Self {
            model: trimmed_owned(request.model.as_deref()),
            effort: trimmed_owned(request.effort.as_deref()),
            allow_custom_model: request.allow_custom_model,
            session_configuration: descriptor.session_configuration.clone(),
        }
    }

    #[must_use]
    pub(in crate::daemon::agent_acp) fn requested_model(&self) -> Option<&str> {
        self.model.as_deref()
    }

    #[must_use]
    pub(in crate::daemon::agent_acp) fn requested_effort(&self) -> Option<&str> {
        self.effort.as_deref()
    }

    #[must_use]
    pub(in crate::daemon::agent_acp) fn model_via_session(&self) -> bool {
        self.model.is_some()
            && !matches!(
                self.session_configuration.model,
                AcpSessionModelTransport::Disabled
            )
    }

    #[must_use]
    pub(in crate::daemon::agent_acp) fn effort_via_session(&self) -> bool {
        self.effort.is_some()
            && !matches!(
                self.session_configuration.effort,
                AcpSessionEffortTransport::Disabled
            )
    }
}

#[derive(Clone, Copy)]
pub(super) struct SessionConfigurationAdvertisement<'a> {
    models: Option<&'a SessionModelState>,
    config_options: &'a [SessionConfigOption],
}

#[must_use]
pub(super) fn advertised_session_configuration(
    response: &NewSessionResponse,
) -> SessionConfigurationAdvertisement<'_> {
    SessionConfigurationAdvertisement {
        models: response.models.as_ref(),
        config_options: response.config_options.as_deref().unwrap_or(&[]),
    }
}

pub(super) async fn apply_requested_session_configuration(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
    session_config: &AcpSessionRequestConfig,
    advertised: SessionConfigurationAdvertisement<'_>,
) -> AcpResult<()> {
    if let Some(model) = session_config.requested_model() {
        apply_model_configuration(
            supervisor,
            connection,
            session_id,
            model,
            session_config,
            advertised,
        )
        .await?;
    }
    if let Some(effort) = session_config.requested_effort() {
        apply_effort_configuration(
            supervisor,
            connection,
            session_id,
            effort,
            session_config,
            advertised.config_options,
        )
        .await?;
    }
    Ok(())
}

async fn apply_model_configuration(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
    model: &str,
    session_config: &AcpSessionRequestConfig,
    advertised: SessionConfigurationAdvertisement<'_>,
) -> AcpResult<()> {
    match &session_config.session_configuration.model {
        AcpSessionModelTransport::Disabled => Ok(()),
        AcpSessionModelTransport::ConfigOption { selector } => {
            apply_config_option_value(
                supervisor,
                connection,
                session_id,
                selector,
                Some("model"),
                model,
                advertised.config_options,
                "model",
            )
            .await
        }
        AcpSessionModelTransport::SessionModel => {
            if !session_config.allow_custom_model
                && let Some(models) = advertised.models
            {
                let available = models
                    .available_models
                    .iter()
                    .any(|candidate| candidate.model_id.0.as_ref() == model);
                if !available {
                    return Err(AcpError::new(
                        -32603,
                        format!("ACP session model '{model}' is not advertised"),
                    ));
                }
            }
            send_set_model(supervisor, connection, session_id, model).await
        }
    }
}

async fn apply_effort_configuration(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
    effort: &str,
    session_config: &AcpSessionRequestConfig,
    config_options: &[SessionConfigOption],
) -> AcpResult<()> {
    match &session_config.session_configuration.effort {
        AcpSessionEffortTransport::Disabled => Ok(()),
        AcpSessionEffortTransport::ConfigOption { selector } => {
            apply_config_option_value(
                supervisor,
                connection,
                session_id,
                selector,
                Some("thought_level"),
                effort,
                config_options,
                "effort",
            )
            .await
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "ACP config option updates need shared session, selector, value, and diagnostics context"
)]
async fn apply_config_option_value(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
    selector: &AcpSessionConfigOptionBinding,
    default_category: Option<&str>,
    requested_value: &str,
    config_options: &[SessionConfigOption],
    field_name: &str,
) -> AcpResult<()> {
    let option =
        find_config_option(config_options, selector, default_category).ok_or_else(|| {
            AcpError::new(
                -32603,
                format!("ACP session config option for {field_name} is not advertised"),
            )
        })?;
    let value = select_config_value(option, requested_value).ok_or_else(|| {
        AcpError::new(
            -32603,
            format!(
                "ACP session config option '{}' does not accept '{}'",
                option.id, requested_value
            ),
        )
    })?;
    send_set_config_option(supervisor, connection, session_id, option, value).await
}

fn find_config_option<'a>(
    config_options: &'a [SessionConfigOption],
    selector: &AcpSessionConfigOptionBinding,
    default_category: Option<&str>,
) -> Option<&'a SessionConfigOption> {
    let requested_id = selector.option_id.as_deref();
    let requested_category = selector.category.as_deref().or(default_category);
    config_options.iter().find(|option| {
        requested_id.is_some_and(|id| option.id.0.as_ref() == id)
            || requested_category.is_some_and(|category| {
                option
                    .category
                    .as_ref()
                    .is_some_and(|candidate| session_config_category_name(candidate) == category)
            })
    })
}

fn select_config_value<'a>(
    option: &'a SessionConfigOption,
    requested_value: &str,
) -> Option<&'a SessionConfigValueId> {
    match &option.kind {
        SessionConfigKind::Select(select) => select_options(select)
            .into_iter()
            .find(|candidate| candidate.value.0.as_ref() == requested_value)
            .map(|candidate| &candidate.value),
        #[allow(unreachable_patterns)]
        _ => None,
    }
}

fn select_options(select: &SessionConfigSelect) -> Vec<&SessionConfigSelectOption> {
    match &select.options {
        SessionConfigSelectOptions::Ungrouped(options) => options.iter().collect(),
        SessionConfigSelectOptions::Grouped(groups) => {
            groups.iter().flat_map(grouped_options).collect::<Vec<_>>()
        }
        _ => Vec::new(),
    }
}

fn grouped_options(
    group: &SessionConfigSelectGroup,
) -> impl Iterator<Item = &SessionConfigSelectOption> {
    group.options.iter()
}

fn session_config_category_name(category: &SessionConfigOptionCategory) -> &str {
    match category {
        SessionConfigOptionCategory::Mode => "mode",
        SessionConfigOptionCategory::Model => "model",
        SessionConfigOptionCategory::ThoughtLevel => "thought_level",
        SessionConfigOptionCategory::Other(value) => value.as_str(),
        _ => "other",
    }
}

async fn send_set_config_option(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
    option: &SessionConfigOption,
    value: &SessionConfigValueId,
) -> AcpResult<()> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/set_config_option"));
    connection
        .send_request(SetSessionConfigOptionRequest::new(
            session_id.clone(),
            option.id.clone(),
            value.clone(),
        ))
        .block_task()
        .await?;
    Ok(())
}

async fn send_set_model(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
    model: &str,
) -> AcpResult<()> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/set_model"));
    connection
        .send_request(SetSessionModelRequest::new(
            session_id.clone(),
            model.to_string(),
        ))
        .block_task()
        .await?;
    Ok(())
}

fn trimmed_owned(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}
