use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;
use crate::session::types::{SessionLogEntry, SessionTransition, TaskCheckpoint};
use crate::workspace::layout::SessionLayout;
use crate::workspace::utc_now;

use super::files;

/// Append a transition entry to the session's audit log.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn append_log_entry(
    layout: &SessionLayout,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    files::validate_session_id(&layout.session_id)?;
    let lock_name = format!("log-{}", layout.session_id);
    files::with_lock(layout, &lock_name, || {
        let path = files::log_path(layout);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| files::io_err(&error))?;
        }
        let sequence = next_log_sequence(&path);
        let entry = SessionLogEntry {
            sequence,
            recorded_at: utc_now(),
            session_id: layout.session_id.clone(),
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
pub(crate) fn load_log_entries(
    layout: &SessionLayout,
) -> Result<Vec<SessionLogEntry>, CliError> {
    files::read_json_lines(&files::log_path(layout), "session log")
}

/// Append a checkpoint entry for a task.
///
/// # Errors
/// Returns `CliError` on I/O or serialization failures.
pub(crate) fn append_task_checkpoint(
    layout: &SessionLayout,
    task_id: &str,
    checkpoint: &TaskCheckpoint,
) -> Result<(), CliError> {
    let lock_name = format!("checkpoint-{}-{task_id}", layout.session_id);
    files::with_lock(layout, &lock_name, || {
        let path = files::checkpoints_path(layout, task_id);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| files::io_err(&error))?;
        }
        files::append_json_line(&path, checkpoint)
    })
}

/// Load checkpoints for a single task.
///
/// # Errors
/// Returns `CliError` on parse or I/O failure.
pub(crate) fn load_task_checkpoints(
    layout: &SessionLayout,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    files::read_json_lines(
        &files::checkpoints_path(layout, task_id),
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

// ---------------------------------------------------------------------------
// Legacy adapters — callers not yet migrated to `SessionLayout`.
// Every call site carries `TODO(b-task-8)`.
// ---------------------------------------------------------------------------

/// Legacy: append log entry by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `append_log_entry(layout, ...)`.
pub(crate) fn append_log_entry_legacy(
    project_dir: &Path,
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    let layout = files::layout_from_project_dir(project_dir, session_id)?;
    append_log_entry(&layout, transition, actor_id, reason)
}

/// Legacy: load log entries by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `load_log_entries(layout)`.
pub(crate) fn load_log_entries_legacy(
    project_dir: &Path,
    session_id: &str,
) -> Result<Vec<SessionLogEntry>, CliError> {
    let layout = files::layout_from_project_dir(project_dir, session_id)?;
    load_log_entries(&layout)
}

/// Legacy: append task checkpoint by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `append_task_checkpoint(layout, ...)`.
pub(crate) fn append_task_checkpoint_legacy(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
    checkpoint: &TaskCheckpoint,
) -> Result<(), CliError> {
    let layout = files::layout_from_project_dir(project_dir, session_id)?;
    append_task_checkpoint(&layout, task_id, checkpoint)
}

/// Legacy: load task checkpoints by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `load_task_checkpoints(layout, ...)`.
pub(crate) fn load_task_checkpoints_legacy(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    let layout = files::layout_from_project_dir(project_dir, session_id)?;
    load_task_checkpoints(&layout, task_id)
}
