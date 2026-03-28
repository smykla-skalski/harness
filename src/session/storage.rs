use std::collections::BTreeMap;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs_err as fs;
use fs2::FileExt;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, validate_safe_segment, write_json_pretty};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::workspace::{project_context_dir, utc_now};

use super::types::{CURRENT_VERSION, SessionLogEntry, SessionState, SessionTransition};

fn orchestration_root(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir).join("orchestration")
}

fn sessions_root(project_dir: &Path) -> PathBuf {
    orchestration_root(project_dir).join("sessions")
}

fn validate_session_id(session_id: &str) -> Result<(), CliError> {
    validate_safe_segment(session_id)
}

pub(crate) fn session_dir(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    validate_session_id(session_id)?;
    Ok(sessions_root(project_dir).join(session_id))
}

fn state_path(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("state.json"))
}

fn log_path(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("log.jsonl"))
}

fn active_registry_path(project_dir: &Path) -> PathBuf {
    orchestration_root(project_dir).join("active.json")
}

fn lock_path(project_dir: &Path, name: &str) -> PathBuf {
    orchestration_root(project_dir)
        .join(".locks")
        .join(format!("{name}.lock"))
}

fn open_lock_file(path: &Path) -> Result<File, CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
    }
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(|error| io_err(&error))
}

fn with_lock<T>(
    project_dir: &Path,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let file = open_lock_file(&lock_path(project_dir, name))?;
    file.lock_exclusive().map_err(|error| io_err(&error))?;
    let result = action();
    let unlock = file.unlock().map_err(|error| io_err(&error));
    match (result, unlock) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(error), _) | (Ok(_), Err(error)) => Err(error),
    }
}

fn io_err(error: &dyn fmt::Display) -> CliError {
    CliErrorKind::workflow_io(format!("session storage: {error}")).into()
}

/// Build a `VersionedJsonRepository` for the session state file.
pub(crate) fn state_repository(
    project_dir: &Path,
    session_id: &str,
) -> Result<VersionedJsonRepository<SessionState>, CliError> {
    Ok(VersionedJsonRepository::new(
        state_path(project_dir, session_id)?,
        CURRENT_VERSION,
    ))
}

/// Load session state, returning `None` if the state file does not exist.
///
/// # Errors
/// Returns `CliError` on I/O or parse failures.
pub(crate) fn load_state(
    project_dir: &Path,
    session_id: &str,
) -> Result<Option<SessionState>, CliError> {
    state_repository(project_dir, session_id)?.load()
}

/// Save session state only when the session does not already exist.
///
/// # Errors
/// Returns `CliError` on I/O or serialization failures.
pub(crate) fn create_state(
    project_dir: &Path,
    session_id: &str,
    state: &SessionState,
) -> Result<bool, CliError> {
    let repository = state_repository(project_dir, session_id)?;
    let mut created = false;
    let _ = repository.update(|current| {
        if current.is_some() {
            return Ok(current);
        }
        created = true;
        Ok(Some(state.clone()))
    })?;
    Ok(created)
}

/// Load, modify, and save session state under an exclusive lock.
///
/// # Errors
/// Returns `CliError` on I/O, parse, or serialization failures, or if state is missing.
pub(crate) fn update_state<F>(
    project_dir: &Path,
    session_id: &str,
    update: F,
) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<(), CliError>,
{
    state_repository(project_dir, session_id)?
        .update(|state| {
            let Some(mut state) = state else {
                return Err(CliErrorKind::session_not_active(format!(
                    "session '{session_id}' not found"
                ))
                .into());
            };
            state.state_version += 1;
            state.updated_at = utc_now();
            update(&mut state)?;
            Ok(Some(state))
        })
        .and_then(|result| {
            result.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
            })
        })
}

/// Append a transition entry to the session's audit log.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn append_log_entry(
    project_dir: &Path,
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    validate_session_id(session_id)?;
    with_lock(project_dir, &format!("log-{session_id}"), || {
        let path = log_path(project_dir, session_id)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
        }
        let sequence = next_log_sequence(&path);
        let entry = SessionLogEntry {
            sequence,
            recorded_at: utc_now(),
            session_id: session_id.to_string(),
            transition,
            actor_id: actor_id.map(ToString::to_string),
            reason: reason.map(ToString::to_string),
        };
        append_json_line(&path, &entry)
    })
}

fn next_log_sequence(path: &Path) -> u64 {
    let Ok(content) = fs::read_to_string(path) else {
        return 1;
    };
    let count = content
        .lines()
        .filter(|line| !line.trim().is_empty())
        .count();
    (count as u64) + 1
}

fn append_json_line<T: Serialize>(path: &Path, value: &T) -> Result<(), CliError> {
    let line = serde_json::to_string(value)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("session log: {error}")))?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| io_err(&error))?;
    writeln!(file, "{line}").map_err(|error| io_err(&error))?;
    Ok(())
}

/// Active session registry: maps session IDs to creation timestamps.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct ActiveRegistry {
    #[serde(default)]
    pub(crate) sessions: BTreeMap<String, String>,
}

/// Register a session ID in the active registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn register_active(project_dir: &Path, session_id: &str) -> Result<(), CliError> {
    validate_session_id(session_id)?;
    with_lock(project_dir, "active-registry", || {
        let path = active_registry_path(project_dir);
        let mut registry = load_active_registry(&path);
        registry.sessions.insert(session_id.to_string(), utc_now());
        write_json_pretty(&path, &registry)
    })
}

/// Remove a session ID from the active registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn deregister_active(project_dir: &Path, session_id: &str) -> Result<(), CliError> {
    validate_session_id(session_id)?;
    with_lock(project_dir, "active-registry", || {
        let path = active_registry_path(project_dir);
        let mut registry = load_active_registry(&path);
        registry.sessions.remove(session_id);
        write_json_pretty(&path, &registry)
    })
}

/// Load the active session registry.
pub(crate) fn load_active_registry_for(project_dir: &Path) -> ActiveRegistry {
    load_active_registry(&active_registry_path(project_dir))
}

fn load_active_registry(path: &Path) -> ActiveRegistry {
    read_json_typed::<ActiveRegistry>(path).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::types::{SessionState, SessionStatus, SessionTransition};

    #[test]
    fn state_round_trip_via_repository() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("test-storage")),
            ],
            || {
                let project = tmp.path().join("project");
                let state = SessionState {
                    schema_version: CURRENT_VERSION,
                    state_version: 0,
                    session_id: "sess-1".into(),
                    context: "test".into(),
                    status: SessionStatus::Active,
                    created_at: "2026-01-01T00:00:00Z".into(),
                    updated_at: "2026-01-01T00:00:00Z".into(),
                    agents: Default::default(),
                    tasks: Default::default(),
                    leader_id: None,
                };
                assert!(create_state(&project, "sess-1", &state).unwrap());
                let loaded = load_state(&project, "sess-1").unwrap().unwrap();
                assert_eq!(loaded.session_id, "sess-1");
            },
        );
    }

    #[test]
    fn append_and_count_log_entries() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("test-log")),
            ],
            || {
                let project = tmp.path().join("project");
                append_log_entry(
                    &project,
                    "sess-1",
                    SessionTransition::SessionStarted {
                        context: "test".into(),
                    },
                    Some("leader"),
                    None,
                )
                .unwrap();
                append_log_entry(
                    &project,
                    "sess-1",
                    SessionTransition::SessionEnded,
                    Some("leader"),
                    None,
                )
                .unwrap();
                let path = log_path(&project, "sess-1").unwrap();
                let content = std::fs::read_to_string(&path).unwrap();
                let lines: Vec<_> = content.lines().filter(|l| !l.trim().is_empty()).collect();
                assert_eq!(lines.len(), 2);
            },
        );
    }

    #[test]
    fn create_state_rejects_unsafe_session_id() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("test-unsafe-session-id")),
            ],
            || {
                let project = tmp.path().join("project");
                let escape_dir = tmp.path().join("escape");
                let unsafe_id = escape_dir.to_string_lossy().into_owned();
                let state = SessionState {
                    schema_version: CURRENT_VERSION,
                    state_version: 0,
                    session_id: unsafe_id.clone(),
                    context: "test".into(),
                    status: SessionStatus::Active,
                    created_at: "2026-01-01T00:00:00Z".into(),
                    updated_at: "2026-01-01T00:00:00Z".into(),
                    agents: Default::default(),
                    tasks: Default::default(),
                    leader_id: None,
                };

                let error = create_state(&project, &unsafe_id, &state).unwrap_err();

                assert_eq!(error.code(), "KSRCLI059");
                assert!(!escape_dir.join("state.json").exists());
            },
        );
    }

    #[test]
    fn active_registry_round_trip() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("test-registry")),
            ],
            || {
                let project = tmp.path().join("project");
                register_active(&project, "sess-a").unwrap();
                register_active(&project, "sess-b").unwrap();
                let registry = load_active_registry_for(&project);
                assert_eq!(registry.sessions.len(), 2);
                deregister_active(&project, "sess-a").unwrap();
                let registry = load_active_registry_for(&project);
                assert_eq!(registry.sessions.len(), 1);
                assert!(registry.sessions.contains_key("sess-b"));
            },
        );
    }
}
