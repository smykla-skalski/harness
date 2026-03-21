use std::fs;
use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_json_pretty};
use crate::observe::types::ObserverState;
use crate::workspace::harness_data_root;

fn state_file_path(session_id: &str) -> PathBuf {
    let observe_dir = harness_data_root().join("observe");
    let _ = fs::create_dir_all(&observe_dir);
    observe_dir.join(format!("{session_id}.state"))
}

pub(crate) fn load_observer_state(session_id: &str) -> Result<ObserverState, CliError> {
    let state_path = state_file_path(session_id);
    if state_path.exists() {
        let content = read_text(&state_path).map_err(|error| -> CliError {
            CliErrorKind::session_parse_error(format!("cannot read state file: {error}")).into()
        })?;
        serde_json::from_str(&content).map_err(|error| {
            CliErrorKind::session_parse_error(format!("invalid state file JSON: {error}")).into()
        })
    } else {
        Ok(ObserverState::default_for_session(session_id))
    }
}

pub(crate) fn save_observer_state(session_id: &str, state: &ObserverState) -> Result<(), CliError> {
    let state_path = state_file_path(session_id);
    write_json_pretty(&state_path, state).map_err(|error| {
        CliErrorKind::session_parse_error(format!("cannot write state file: {error}")).into()
    })
}
