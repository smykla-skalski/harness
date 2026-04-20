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
use crate::workspace::harness_data_root;
use crate::workspace::layout::{SessionLayout, sessions_root as workspace_sessions_root};

/// Validate a session id (must not be empty or contain path traversal).
pub(super) fn validate_session_id(session_id: &str) -> Result<(), CliError> {
    validate_safe_segment(session_id)
}

/// Path to the state file for a session.
pub(super) fn state_path(layout: &SessionLayout) -> PathBuf {
    layout.state_file()
}

/// Path to the append-only event log for a session.
pub(super) fn log_path(layout: &SessionLayout) -> PathBuf {
    layout.log_file()
}

/// Path to the checkpoints JSONL file for a task inside a session.
pub(super) fn checkpoints_path(layout: &SessionLayout, task_id: &str) -> PathBuf {
    layout.tasks_dir().join(task_id).join("checkpoints.jsonl")
}

/// Path to the per-project active-session registry.
pub(super) fn active_registry_path(layout: &SessionLayout) -> PathBuf {
    layout.active_registry()
}

/// Path to a named advisory lock file for a session.
fn lock_path(layout: &SessionLayout, name: &str) -> PathBuf {
    layout.locks_dir().join(format!("{name}.lock"))
}

/// Run `action` under an exclusive file lock keyed by `name`.
pub(super) fn with_lock<T>(
    layout: &SessionLayout,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    with_exclusive_flock(
        &lock_path(layout, name),
        FlockErrorContext::new("session storage"),
        action,
    )
}

/// Convenience for wrapping an I/O error in a session-storage `CliError`.
pub(super) fn io_err(error: &dyn fmt::Display) -> CliError {
    CliErrorKind::workflow_io(format!("session storage: {error}")).into()
}

/// List session ids in a project directory.
///
/// Reads `<project_dir>/` and returns every subdirectory name that does not
/// start with `.` (skips `.active.json` and similar).
pub(crate) fn list_session_ids_in_project_dir(project_dir: &Path) -> Result<Vec<String>, CliError> {
    if !project_dir.is_dir() {
        return Ok(Vec::new());
    }

    let mut session_ids: Vec<String> = fs::read_dir(project_dir)
        .map_err(|error| io_err(&error))?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            // Skip hidden files (e.g. .active.json, .origin)
            if name.starts_with('.') {
                return None;
            }
            entry
                .file_type()
                .ok()
                .filter(FileType::is_dir)
                .map(|_| name)
        })
        .collect();
    session_ids.sort_unstable();
    Ok(session_ids)
}

/// Append a single JSON-serialisable value as a newline to `path`.
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

// ---------------------------------------------------------------------------
// Project-dir → SessionLayout helpers.
//
// Callers that receive a `project_dir` from CLI/HTTP rather than a fully
// constructed `SessionLayout` go through these helpers to derive the layout.
// ---------------------------------------------------------------------------

/// Derive `(sessions_root, project_name)` from a `project_dir`.
///
/// Single canonical place that extracts a project name from a directory
/// path. Used by `layout_from_project_dir`, `list_known_session_ids`, and
/// `registry::load_active_registry_for`.
///
/// # Errors
/// Returns `CliError` (variant `InvalidProjectDir`) when `project_dir` has no
/// `file_name` component (e.g. it is `/` or ends with `..`). In debug builds
/// the same condition panics immediately to surface the bug earlier.
pub(crate) fn project_layout_parts_from_dir(
    project_dir: &Path,
) -> Result<(PathBuf, String), CliError> {
    debug_assert!(
        project_dir.file_name().is_some(),
        "project_dir must have a file_name component: {}",
        project_dir.display()
    );
    let project_name = project_dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or_else(|| -> CliError {
            CliErrorKind::invalid_project_dir(project_dir.to_string_lossy().into_owned()).into()
        })?;
    let sessions_root = workspace_sessions_root(&harness_data_root());
    Ok((sessions_root, project_name))
}

/// Build a `SessionLayout` from a `project_dir` + `session_id` pair.
///
/// Used by callers (CLI, HTTP handlers, daemon services) that receive a
/// project path from a user and need to derive the canonical
/// `<sessions_root>/<project_name>/<session_id>` layout.
///
/// # Errors
/// Returns `CliError` (variant `InvalidProjectDir`) when `project_dir` has no
/// `file_name` component. See [`project_layout_parts_from_dir`].
pub fn layout_from_project_dir(
    project_dir: &Path,
    session_id: &str,
) -> Result<SessionLayout, CliError> {
    let (sessions_root, project_name) = project_layout_parts_from_dir(project_dir)?;
    Ok(SessionLayout {
        sessions_root,
        project_name,
        session_id: session_id.to_string(),
    })
}

/// List known session ids for a project directory.
///
/// # Errors
/// Returns `CliError` when `project_dir` has no `file_name` component, or on
/// underlying I/O failures.
pub(crate) fn list_known_session_ids(project_dir: &Path) -> Result<Vec<String>, CliError> {
    let (sessions_root, project_name) = project_layout_parts_from_dir(project_dir)?;
    list_session_ids_in_project_dir(&sessions_root.join(project_name))
}
