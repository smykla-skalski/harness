//! Live session-state tap: session notifications and config responses feed
//! the supervisor's [`AcpAgentSessionState`] surfaced through inspect.

use agent_client_protocol::schema::MaybeUndefined;
use agent_client_protocol::schema::v1::{
    NewSessionResponse, SessionConfigKind, SessionConfigOption, SessionUpdate,
    SetSessionConfigOptionResponse,
};

use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::agent_acp::AcpSessionConfigOptionState;

use super::session_config::session_config_category_name;

pub(super) fn seed_from_new_session(
    supervisor: &AcpSessionSupervisor,
    response: &NewSessionResponse,
) {
    let config_options = response.config_options.as_deref();
    let mode_id = response
        .modes
        .as_ref()
        .map(|modes| modes.current_mode_id.0.to_string());
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

pub(super) fn apply_session_update(supervisor: &AcpSessionSupervisor, update: &SessionUpdate) {
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
        SessionUpdate::SessionInfoUpdate(update) => supervisor.mutate_session_state(|state| {
            apply_maybe(&update.title, &mut state.title);
            apply_maybe(&update.updated_at, &mut state.updated_at);
        }),
        _ => {}
    }
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
