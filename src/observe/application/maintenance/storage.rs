use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write as _};
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::agents::storage::project_context_root_from_session_path;
use crate::app::command_context::resolve_project_dir;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::observe::session;
use crate::observe::types::ObserverState;
use crate::workspace::{project_context_dir, utc_now};

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ObserverStateEvent {
    sequence: u64,
    recorded_at: String,
    state: ObserverState,
}

pub(crate) fn default_project_context_root() -> PathBuf {
    project_context_dir(&resolve_project_dir(None))
}

pub(crate) fn project_context_root_for_session_path(session_path: &Path) -> PathBuf {
    project_context_root_from_session_path(session_path)
        .unwrap_or_else(default_project_context_root)
}

pub(crate) fn resolve_project_context_root(
    session_id: &str,
    project_hint: Option<&str>,
    agent: Option<HookAgent>,
) -> Result<PathBuf, CliError> {
    match session::find_session_for_agent(session_id, project_hint, agent) {
        Ok(path) => Ok(project_context_root_for_session_path(&path)),
        Err(error) if error.code() == "KSRCLI080" => Ok(default_project_context_root()),
        Err(error) => Err(error),
    }
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
) -> Result<ObserverState, CliError> {
    Ok(
        read_latest_state(project_context_root, observe_id, session_id)?
            .unwrap_or_else(|| ObserverState::default_for_session(session_id)),
    )
}

pub(crate) fn save_observer_state(
    project_context_root: &Path,
    observe_id: &str,
    state: &ObserverState,
) -> Result<ObserverState, CliError> {
    with_lock(project_context_root, observe_id, || {
        let current = read_latest_state(project_context_root, observe_id, &state.session_id)?
            .unwrap_or_else(|| ObserverState::default_for_session(&state.session_id));
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
) -> Result<Option<ObserverState>, CliError> {
    let events = events_path(project_context_root, observe_id);
    if events.exists() {
        return read_latest_event_state(&events, session_id);
    }
    let snapshot = snapshot_path(project_context_root, observe_id);
    if snapshot.exists() {
        let state: ObserverState = read_json_typed(&snapshot).map_err(|error| {
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
) -> Result<Option<ObserverState>, CliError> {
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
    state: ObserverState,
    session_id: &str,
) -> Result<ObserverState, CliError> {
    if state.session_id == session_id {
        return Ok(state);
    }
    Err(CliError::from(CliErrorKind::session_parse_error(format!(
        "observe state belongs to session '{}' but '{}' was requested",
        state.session_id, session_id
    ))))
}

fn append_event(
    project_context_root: &Path,
    observe_id: &str,
    state: &ObserverState,
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
