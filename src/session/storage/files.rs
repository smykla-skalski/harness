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

/// List all session ids recorded under the new sessions layout for a project.
///
/// Reads `<sessions_root>/<project_name>/` and returns every subdirectory name
/// that does not start with `.` (skips `.active.json` and similar).
///
/// TODO(b-task-8): will be the primary list function after cascade migration.
#[allow(dead_code)]
pub(crate) fn list_known_session_ids_for_layout(layout: &SessionLayout) -> Result<Vec<String>, CliError> {
    list_session_ids_in_project_dir(&layout.project_dir())
}

/// List session ids in a project directory (shared between new layout and
/// legacy-compat adapter).
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

// ---------------------------------------------------------------------------
// Legacy adapter — used by callers that have not yet been migrated to
// `SessionLayout`.  Every call site is annotated with `TODO(b-task-8)` so
// Task 8 can finish the full cascade.
// ---------------------------------------------------------------------------

/// Derive `(sessions_root, project_name)` from a legacy `project_dir`.
///
/// This is the single canonical place that extracts a project name from a
/// directory path.  All three legacy paths (`layout_from_project_dir`,
/// `list_known_session_ids`, and `registry::load_active_registry_for`) call
/// this helper so the derivation logic is not duplicated.
///
/// # TODO(b-task-8)
/// Remove once every legacy adapter is gone.
pub(crate) fn project_layout_parts_from_dir(project_dir: &Path) -> (PathBuf, String) {
    let sessions_root = workspace_sessions_root(&harness_data_root());
    let project_name = project_dir
        .file_name()
        .map_or_else(|| "project".to_string(), |n| n.to_string_lossy().into_owned());
    (sessions_root, project_name)
}

/// Build a `SessionLayout` from the old-style `project_dir` + `session_id`
/// pair.
///
/// # TODO(b-task-8)
/// This adapter exists only to keep callers compiling during the Task 7
/// storage rewrite.  Task 8 will rewrite every caller to pass a real
/// `SessionLayout` derived from the new sessions path.
///
/// The layout it produces points at the **new** path schema
/// `<sessions_root>/<project_name>/<session_id>`, using the basename of
/// `project_dir` as the project name and `crate::workspace::layout::sessions_root`
/// to anchor the root.
pub(crate) fn layout_from_project_dir(
    project_dir: &Path,
    session_id: &str,
) -> SessionLayout {
    let (sessions_root, project_name) = project_layout_parts_from_dir(project_dir);
    SessionLayout {
        sessions_root,
        project_name,
        session_id: session_id.to_string(),
    }
}

/// Legacy wrapper: `list_known_session_ids` taking `project_dir`.
///
/// # TODO(b-task-8): migrate callers to `list_known_session_ids_for_layout`.
pub(crate) fn list_known_session_ids(project_dir: &Path) -> Result<Vec<String>, CliError> {
    let (sessions_root, project_name) = project_layout_parts_from_dir(project_dir);
    list_session_ids_in_project_dir(&sessions_root.join(project_name))
}
