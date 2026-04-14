use std::fmt;
use std::fs::{FileType, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::validate_safe_segment;
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::workspace::project_context_dir;

pub(super) fn orchestration_root(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir).join("orchestration")
}

fn sessions_root(project_dir: &Path) -> PathBuf {
    orchestration_root(project_dir).join("sessions")
}

pub(super) fn validate_session_id(session_id: &str) -> Result<(), CliError> {
    validate_safe_segment(session_id)
}

pub(super) fn session_dir(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    validate_session_id(session_id)?;
    Ok(sessions_root(project_dir).join(session_id))
}

pub(super) fn state_path(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("state.json"))
}

pub(super) fn log_path(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("log.jsonl"))
}

fn tasks_root(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("tasks"))
}

fn task_dir(project_dir: &Path, session_id: &str, task_id: &str) -> Result<PathBuf, CliError> {
    Ok(tasks_root(project_dir, session_id)?.join(task_id))
}

pub(super) fn checkpoints_path(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
) -> Result<PathBuf, CliError> {
    Ok(task_dir(project_dir, session_id, task_id)?.join("checkpoints.jsonl"))
}

pub(super) fn active_registry_path(project_dir: &Path) -> PathBuf {
    orchestration_root(project_dir).join("active.json")
}

fn lock_path(project_dir: &Path, name: &str) -> PathBuf {
    orchestration_root(project_dir)
        .join(".locks")
        .join(format!("{name}.lock"))
}

pub(super) fn with_lock<T>(
    project_dir: &Path,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    with_exclusive_flock(
        &lock_path(project_dir, name),
        FlockErrorContext::new("session storage"),
        action,
    )
}

pub(super) fn io_err(error: &dyn fmt::Display) -> CliError {
    CliErrorKind::workflow_io(format!("session storage: {error}")).into()
}

pub(crate) fn list_known_session_ids(project_dir: &Path) -> Result<Vec<String>, CliError> {
    let root = sessions_root(project_dir);
    if !root.is_dir() {
        return Ok(Vec::new());
    }

    let mut session_ids: Vec<String> = fs::read_dir(root)
        .map_err(|error| io_err(&error))?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            entry
                .file_type()
                .ok()
                .filter(FileType::is_dir)
                .and_then(|_| entry.file_name().into_string().ok())
        })
        .collect();
    session_ids.sort_unstable();
    Ok(session_ids)
}

pub(super) fn append_json_line<T: Serialize>(path: &Path, value: &T) -> Result<(), CliError> {
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

#[allow(dead_code)]
pub(super) fn read_json_lines<T>(path: &Path, label: &str) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
{
    if !path.is_file() {
        return Ok(Vec::new());
    }

    fs::read_to_string(path)
        .map_err(|error| io_err(&error))?
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line)
                .map_err(|error| CliErrorKind::workflow_parse(format!("{label}: {error}")).into())
        })
        .collect()
}
