use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::layout::SessionLayout;
use crate::workspace::project_context_dir;
use crate::workspace::utc_now;

use super::files;

// ---------------------------------------------------------------------------
// New registry types (Task 7)
// ---------------------------------------------------------------------------

/// Per-project active-session registry.
///
/// Stored at `<sessions_root>/<project_name>/.active.json`.
/// The map key is the session id; the value is the creation timestamp.
///
/// Fields `is_worktree`, `worktree_name`, and `recorded_from_dir` have been
/// dropped: the daemon always creates worktrees so they are redundant.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct ActiveRegistry {
    #[serde(default)]
    pub(crate) sessions: BTreeMap<String, String>,
}

// ---------------------------------------------------------------------------
// Registry operations on SessionLayout
// ---------------------------------------------------------------------------

/// Register a session id in the per-project active-session registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn register_active(layout: &SessionLayout) -> Result<(), CliError> {
    files::validate_session_id(&layout.session_id)?;
    files::with_lock(layout, "active-registry", || {
        let path = files::active_registry_path(layout);
        let mut registry = load_registry_at(&path);
        registry
            .sessions
            .insert(layout.session_id.clone(), utc_now());
        write_json_pretty(&path, &registry)
    })
}

/// Remove a session id from the per-project active-session registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn deregister_active(layout: &SessionLayout) -> Result<(), CliError> {
    files::validate_session_id(&layout.session_id)?;
    files::with_lock(layout, "active-registry", || {
        let path = files::active_registry_path(layout);
        let mut registry = load_registry_at(&path);
        registry.sessions.remove(&layout.session_id);
        write_json_pretty(&path, &registry)
    })
}

/// Load the active-session registry for a layout.
#[cfg(test)]
pub(crate) fn load_active_registry_for_layout(layout: &SessionLayout) -> ActiveRegistry {
    load_registry_at(&files::active_registry_path(layout))
}

fn load_registry_at(path: &Path) -> ActiveRegistry {
    read_json_typed::<ActiveRegistry>(path).unwrap_or_default()
}

/// Load the active-session registry for a project directory.
///
/// # Errors
/// Returns `CliError` when `project_dir` has no `file_name` component.
pub(crate) fn load_active_registry_for(project_dir: &Path) -> Result<ActiveRegistry, CliError> {
    let (sessions_root, project_name) = files::project_layout_parts_from_dir(project_dir)?;
    let path = sessions_root.join(project_name).join(".active.json");
    Ok(load_registry_at(&path))
}

// ---------------------------------------------------------------------------
// Project origin — kept for backward compatibility with index discovery.
// TODO(b-task-8): remove once daemon/index/contexts.rs is migrated.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ProjectOriginRecord {
    pub(crate) recorded_from_dir: String,
    pub(crate) repository_root: Option<String>,
    pub(crate) checkout_root: Option<String>,
    pub(crate) recorded_at: String,
}

const PROJECT_ORIGIN_FILE: &str = "project-origin.json";

/// Record the originating project directory so cross-project discovery can
/// recover it later.
///
/// # Errors
/// Returns `CliError` on I/O failures.
///
/// # TODO(b-task-8): once index/contexts.rs is migrated, decide whether this
/// file moves under `SessionLayout` or disappears entirely.
pub(crate) fn record_project_origin(project_dir: &Path) -> Result<(), CliError> {
    use crate::workspace::resolve_git_checkout_identity;
    let context_root = project_context_dir(project_dir);
    let path = context_root.join(PROJECT_ORIGIN_FILE);
    let identity = resolve_git_checkout_identity(project_dir);
    let previous = load_project_origin(&context_root);
    let origin = ProjectOriginRecord {
        recorded_from_dir: project_dir.to_string_lossy().to_string(),
        repository_root: identity
            .as_ref()
            .map(|value| value.repository_root.display().to_string()),
        checkout_root: identity
            .as_ref()
            .map(|value| value.checkout_root.display().to_string()),
        recorded_at: utc_now(),
    };
    let origin = merge_project_origin(origin, previous.as_ref());
    write_json_pretty(&path, &origin)
}

/// Load the recorded project origin for a context root.
#[must_use]
pub(crate) fn load_project_origin(context_root: &Path) -> Option<ProjectOriginRecord> {
    let path = context_root.join(PROJECT_ORIGIN_FILE);
    read_json_typed::<ProjectOriginRecord>(&path).ok()
}

pub(super) fn merge_project_origin(
    mut origin: ProjectOriginRecord,
    previous: Option<&ProjectOriginRecord>,
) -> ProjectOriginRecord {
    let Some(previous) = previous else {
        return origin;
    };

    if origin.repository_root.is_none() {
        origin.repository_root.clone_from(&previous.repository_root);
    }
    if origin.checkout_root.is_none() {
        origin.checkout_root.clone_from(&previous.checkout_root);
    }
    origin
}
