use tracing::warn;

use crate::errors::CliError;
use crate::observe::application::maintenance::{load_observer_state, save_observer_state};
use crate::observe::types::IssueCode;

pub(in crate::observe::application) fn execute_mute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    for code_str in codes.split(',') {
        if let Some(code) = IssueCode::from_label(code_str.trim()) {
            if !state.muted_codes.contains(&code) {
                state.muted_codes.push(code);
            }
        } else {
            warn!(code = code_str.trim(), "unknown issue code");
        }
    }
    save_observer_state(session_id, &state)?;
    println!(
        "Muted codes: {}",
        state
            .muted_codes
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok(0)
}

pub(in crate::observe::application) fn execute_unmute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    for code_str in codes.split(',') {
        if let Some(code) = IssueCode::from_label(code_str.trim()) {
            state.muted_codes.retain(|muted| *muted != code);
        }
    }
    save_observer_state(session_id, &state)?;
    println!(
        "Muted codes: {}",
        state
            .muted_codes
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok(0)
}
