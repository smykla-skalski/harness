use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;
use crate::session::types::{SessionLogEntry, SessionTransition, TaskCheckpoint};
use crate::workspace::utc_now;

use super::files;

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
    files::validate_session_id(session_id)?;
    files::with_lock(project_dir, &format!("log-{session_id}"), || {
        let path = files::log_path(project_dir, session_id)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| files::io_err(&error))?;
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
        files::append_json_line(&path, &entry)
    })
}

/// Load the append-only session audit log.
///
/// # Errors
/// Returns `CliError` on parse or I/O failure.
#[allow(dead_code)]
pub(crate) fn load_log_entries(
    project_dir: &Path,
    session_id: &str,
) -> Result<Vec<SessionLogEntry>, CliError> {
    files::read_json_lines(&files::log_path(project_dir, session_id)?, "session log")
}

/// Append a checkpoint entry for a task.
///
/// # Errors
/// Returns `CliError` on I/O or serialization failures.
pub(crate) fn append_task_checkpoint(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
    checkpoint: &TaskCheckpoint,
) -> Result<(), CliError> {
    files::with_lock(
        project_dir,
        &format!("checkpoint-{session_id}-{task_id}"),
        || {
            let path = files::checkpoints_path(project_dir, session_id, task_id)?;
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(|error| files::io_err(&error))?;
            }
            files::append_json_line(&path, checkpoint)
        },
    )
}

/// Load checkpoints for a single task.
///
/// # Errors
/// Returns `CliError` on parse or I/O failure.
#[allow(dead_code)]
pub(crate) fn load_task_checkpoints(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    files::read_json_lines(
        &files::checkpoints_path(project_dir, session_id, task_id)?,
        "task checkpoints",
    )
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
