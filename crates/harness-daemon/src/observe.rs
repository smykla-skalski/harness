use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write as _};
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::workspace::utc_now;

#[path = "../../../src/observe/application/session_event.rs"]
mod session_event;
pub mod application {
    pub mod session_event {
        pub use super::super::session_event::*;
    }
}

#[path = "../../../src/observe/classifier/mod.rs"]
pub(crate) mod classifier;
#[path = "../../../src/observe/patterns.rs"]
pub(crate) mod patterns;
#[path = "../../../src/observe/text.rs"]
mod text;
#[path = "../../../src/observe/types/mod.rs"]
pub(crate) mod types;

pub(crate) use text::{redact_details, truncate_details};

pub mod dump {
    pub(crate) fn tool_result_text(block: &serde_json::Value) -> String {
        let content = &block["content"];
        if let Some(items) = content.as_array() {
            items
                .iter()
                .filter(|item| item["type"].as_str() == Some("text"))
                .filter_map(|item| item["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            content.as_str().unwrap_or_default().to_string()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ObserverStateEvent {
    sequence: u64,
    recorded_at: String,
    state: types::ObserverState,
}

fn observe_root(project_context_root: &Path, observe_id: &str) -> PathBuf {
    project_context_root
        .join("agents")
        .join("observe")
        .join(observe_id)
}

fn events_path(project_context_root: &Path, observe_id: &str) -> PathBuf {
    observe_root(project_context_root, observe_id).join("events.jsonl")
}

fn snapshot_path(project_context_root: &Path, observe_id: &str) -> PathBuf {
    observe_root(project_context_root, observe_id).join("snapshot.json")
}

fn lock_path(project_context_root: &Path, observe_id: &str) -> PathBuf {
    project_context_root
        .join("agents")
        .join(".locks")
        .join(format!("observe-{observe_id}.lock"))
}

fn with_lock<T>(
    project_context_root: &Path,
    observe_id: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    with_exclusive_flock(
        &lock_path(project_context_root, observe_id),
        FlockErrorContext::new("observer storage"),
        action,
    )
}

pub(crate) fn load_observer_state(
    project_context_root: &Path,
    observe_id: &str,
    session_id: &str,
) -> Result<types::ObserverState, CliError> {
    Ok(
        read_latest_state(project_context_root, observe_id, session_id)?
            .unwrap_or_else(|| types::ObserverState::default_for_session(session_id)),
    )
}

pub(crate) fn save_observer_state(
    project_context_root: &Path,
    observe_id: &str,
    state: &types::ObserverState,
) -> Result<types::ObserverState, CliError> {
    with_lock(project_context_root, observe_id, || {
        let current = read_latest_state(project_context_root, observe_id, &state.session_id)?
            .unwrap_or_else(|| types::ObserverState::default_for_session(&state.session_id));
        if current.state_version != state.state_version {
            return Err(conflict_error(state.state_version, current.state_version));
        }

        let mut next = state.clone();
        next.state_version = current.state_version.saturating_add(1);
        append_event(project_context_root, observe_id, &next)?;
        write_json_pretty(&snapshot_path(project_context_root, observe_id), &next).map_err(
            |error| {
                CliError::from(CliErrorKind::session_parse_error(format!(
                    "cannot write observer snapshot: {error}"
                )))
            },
        )?;
        Ok(next)
    })
}

pub(crate) fn is_observer_conflict(error: &CliError) -> bool {
    error
        .details()
        .is_some_and(|details| details.contains("observer state conflict"))
}

fn read_latest_state(
    project_context_root: &Path,
    observe_id: &str,
    session_id: &str,
) -> Result<Option<types::ObserverState>, CliError> {
    let events = events_path(project_context_root, observe_id);
    if events.exists() {
        return read_latest_event_state(&events, session_id);
    }
    let snapshot = snapshot_path(project_context_root, observe_id);
    if snapshot.exists() {
        let state: types::ObserverState = read_json_typed(&snapshot).map_err(|error| {
            CliError::from(CliErrorKind::session_parse_error(format!(
                "cannot read observer snapshot: {error}"
            )))
        })?;
        return ensure_session_identity(state, session_id).map(Some);
    }
    Ok(None)
}

fn read_latest_event_state(
    path: &Path,
    session_id: &str,
) -> Result<Option<types::ObserverState>, CliError> {
    let file = File::open(path).map_err(|error| io_err(&error))?;
    let reader = BufReader::new(file);
    let mut latest = None;
    for line in reader.lines() {
        let line = line.map_err(|error| io_err(&error))?;
        if line.trim().is_empty() {
            continue;
        }
        let event: ObserverStateEvent = serde_json::from_str(&line).map_err(|error| {
            CliError::from(CliErrorKind::session_parse_error(format!(
                "invalid observer event JSON: {error}"
            )))
        })?;
        latest = Some(event.state);
    }
    latest
        .map(|state| ensure_session_identity(state, session_id))
        .transpose()
}

fn ensure_session_identity(
    state: types::ObserverState,
    session_id: &str,
) -> Result<types::ObserverState, CliError> {
    if state.session_id == session_id {
        return Ok(state);
    }
    Err(CliError::from(CliErrorKind::session_parse_error(format!(
        "observe state belongs to session '{}' but '{session_id}' was requested",
        state.session_id
    ))))
}

fn append_event(
    project_context_root: &Path,
    observe_id: &str,
    state: &types::ObserverState,
) -> Result<(), CliError> {
    let path = events_path(project_context_root, observe_id);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
    }
    let event = ObserverStateEvent {
        sequence: next_sequence(&path)?,
        recorded_at: utc_now(),
        state: state.clone(),
    };
    let line = serde_json::to_string(&event).map_err(|error| {
        CliError::from(CliErrorKind::session_parse_error(format!(
            "cannot serialize observer event: {error}"
        )))
    })?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| io_err(&error))?;
    writeln!(file, "{line}").map_err(|error| io_err(&error))
}

fn next_sequence(path: &Path) -> Result<u64, CliError> {
    if !path.exists() {
        return Ok(1);
    }
    let file = File::open(path).map_err(|error| io_err(&error))?;
    let reader = BufReader::new(file);
    let mut last = 0;
    for line in reader.lines() {
        let line = line.map_err(|error| io_err(&error))?;
        if line.trim().is_empty() {
            continue;
        }
        let event: ObserverStateEvent = serde_json::from_str(&line).map_err(|error| {
            CliError::from(CliErrorKind::session_parse_error(format!(
                "invalid observer event JSON: {error}"
            )))
        })?;
        last = event.sequence;
    }
    Ok(last.saturating_add(1))
}

fn conflict_error(expected: u64, actual: u64) -> CliError {
    CliError::from(CliErrorKind::session_parse_error(
        "observer state changed during update; retry the operation",
    ))
    .with_details(format!(
        "observer state conflict: expected version {expected}, found {actual}"
    ))
}

fn io_err(error: &impl ToString) -> CliError {
    CliError::from(CliErrorKind::session_parse_error(error.to_string()))
}
