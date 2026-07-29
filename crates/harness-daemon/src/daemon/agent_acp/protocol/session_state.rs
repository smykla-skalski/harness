//! Live session-state tap: session notifications and config responses feed
//! the supervisor's [`AcpAgentSessionState`] surfaced through inspect.

use agent_client_protocol::Error as AcpError;
use agent_client_protocol::schema::MaybeUndefined;
use agent_client_protocol::schema::v1::{
    ContentBlock, PromptResponse, SessionConfigKind, SessionConfigOption, SessionModeState,
    SessionUpdate, SetSessionConfigOptionResponse, StopReason,
};

use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::agent_acp::{
    AcpAgentTurnResult, AcpSessionConfigOptionState, AgentTurnFailure, AgentTurnFailureCategory,
    AgentTurnFailureStage,
};
use crate::daemon::remote_redaction::redact_known_secrets;

use super::session_config::session_config_category_name;

/// Seed the live state from whichever call opened the session; `session/new`
/// and `session/resume` both report these two.
pub(super) fn seed_from_session_start(
    supervisor: &AcpSessionSupervisor,
    config_options: Option<&[SessionConfigOption]>,
    modes: Option<&SessionModeState>,
) {
    let mode_id = modes.map(|modes| modes.current_mode_id.0.to_string());
    if config_options.is_none() && mode_id.is_none() {
        return;
    }
    supervisor.mutate_session_state(|state| {
        if let Some(options) = config_options {
            state.config_options = config_option_states(options);
        }
        if let Some(mode_id) = mode_id {
            state.current_mode_id = Some(mode_id);
        }
    });
}

pub(super) fn record_config_snapshot(
    supervisor: &AcpSessionSupervisor,
    response: &SetSessionConfigOptionResponse,
) {
    supervisor.mutate_session_state(|state| {
        state.config_options = config_option_states(&response.config_options);
    });
}

pub(super) fn begin_turn(supervisor: &AcpSessionSupervisor) {
    supervisor.begin_turn_report();
    supervisor.mutate_session_state(|state| {
        state.last_stop_reason = None;
        state.last_turn_result = None;
        state.last_turn_failure = None;
    });
}

pub(super) fn apply_live_turn_update(supervisor: &AcpSessionSupervisor, update: &SessionUpdate) {
    if let SessionUpdate::AgentMessageChunk(chunk) = update
        && let ContentBlock::Text(text) = &chunk.content
    {
        supervisor.append_turn_report(&text.text);
    }
}

/// Record why a prompt turn stopped, both on the inspectable session state and
/// as a timeline event so a refusal is visible without reading the daemon log.
pub(super) fn record_stop_reason(supervisor: &AcpSessionSupervisor, response: &PromptResponse) {
    let label = stop_reason_label(response.stop_reason);
    let report = supervisor.take_turn_report();
    let failure = stop_reason_failure(response.stop_reason);
    supervisor.mutate_session_state(|state| {
        state.last_stop_reason = Some(label.to_owned());
        state.last_turn_failure = failure;
        if state.last_turn_failure.is_none()
            && let Some(report) = report
        {
            state.last_turn_result = Some(AcpAgentTurnResult {
                report,
                stop_reason: label.to_owned(),
            });
        }
    });
    if let Some(emitter) = supervisor.event_emitter() {
        emitter.emit_turn_ended(label.to_owned());
    }
}

pub(super) fn record_prompt_error(supervisor: &AcpSessionSupervisor, error: &AcpError) {
    supervisor.discard_turn_report();
    let mut failure = error
        .data
        .clone()
        .and_then(|data| serde_json::from_value::<AgentTurnFailure>(data).ok())
        .unwrap_or_else(|| unknown_acp_failure(error));
    failure.stage = AgentTurnFailureStage::Execution;
    failure.automatic_retry_safe = failure.category.automatic_retry_safe();
    failure.detail = bounded_redacted_detail(&failure.detail);
    supervisor.mutate_session_state(|state| {
        state.last_stop_reason = None;
        state.last_turn_result = None;
        state.last_turn_failure = Some(failure);
    });
}

fn bounded_redacted_detail(detail: &str) -> String {
    redact_known_secrets(detail).chars().take(512).collect()
}

fn unknown_acp_failure(error: &AcpError) -> AgentTurnFailure {
    let category = AgentTurnFailureCategory::from_message(&error.message);
    let code = i32::from(error.code);
    AgentTurnFailure::new(
        category,
        AgentTurnFailureStage::Execution,
        format!("ACP session/prompt failed with error code {code}"),
    )
}

fn stop_reason_failure(stop_reason: StopReason) -> Option<AgentTurnFailure> {
    match stop_reason {
        StopReason::Refusal => Some(AgentTurnFailure::new(
            AgentTurnFailureCategory::ProviderRejected,
            AgentTurnFailureStage::Execution,
            "agent refused the prompt",
        )),
        StopReason::Cancelled => Some(AgentTurnFailure::cancelled("agent turn cancelled")),
        _ => None,
    }
}

fn stop_reason_label(stop_reason: StopReason) -> &'static str {
    match stop_reason {
        StopReason::EndTurn => "end_turn",
        StopReason::MaxTokens => "max_tokens",
        StopReason::MaxTurnRequests => "max_turn_requests",
        StopReason::Refusal => "refusal",
        StopReason::Cancelled => "cancelled",
        _ => "unknown",
    }
}

/// Fold a session update into the supervisor's live state.
///
/// Returns the agent-reported title when this update set one, so the caller can
/// persist it into the session index.
pub(super) fn apply_session_update(
    supervisor: &AcpSessionSupervisor,
    update: &SessionUpdate,
) -> Option<String> {
    match update {
        SessionUpdate::ConfigOptionUpdate(update) => supervisor.mutate_session_state(|state| {
            state.config_options = config_option_states(&update.config_options);
        }),
        SessionUpdate::CurrentModeUpdate(update) => supervisor.mutate_session_state(|state| {
            state.current_mode_id = Some(update.current_mode_id.0.to_string());
        }),
        SessionUpdate::AvailableCommandsUpdate(update) => {
            supervisor.mutate_session_state(|state| {
                state.available_commands = update
                    .available_commands
                    .iter()
                    .map(|command| command.name.clone())
                    .collect();
            });
        }
        SessionUpdate::SessionInfoUpdate(update) => {
            supervisor.mutate_session_state(|state| {
                apply_maybe(&update.title, &mut state.title);
                apply_maybe(&update.updated_at, &mut state.updated_at);
            });
            if let MaybeUndefined::Value(title) = &update.title {
                return Some(title.clone());
            }
        }
        _ => {}
    }
    None
}

fn apply_maybe(update: &MaybeUndefined<String>, target: &mut Option<String>) {
    match update {
        MaybeUndefined::Undefined => {}
        MaybeUndefined::Null => *target = None,
        MaybeUndefined::Value(value) => *target = Some(value.clone()),
    }
}

fn config_option_states(options: &[SessionConfigOption]) -> Vec<AcpSessionConfigOptionState> {
    options
        .iter()
        .map(|option| AcpSessionConfigOptionState {
            id: option.id.0.to_string(),
            name: option.name.clone(),
            category: option
                .category
                .as_ref()
                .map(|category| session_config_category_name(category).to_owned()),
            current_value: match &option.kind {
                SessionConfigKind::Select(select) => select.current_value.0.to_string(),
                SessionConfigKind::Boolean(boolean) => boolean.current_value.to_string(),
                _ => String::new(),
            },
        })
        .collect()
}
