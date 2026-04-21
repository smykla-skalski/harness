use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::layout::{SessionLayout, sessions_root as workspace_sessions_root};
use crate::workspace::project_context_dir;
use crate::workspace::utc_now;
use crate::workspace::{harness_data_root, resolve_git_checkout_identity};

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
    let mut paths = BTreeSet::from([sessions_root.join(project_name).join(".active.json")]);
    paths.extend(
        files::adopted_project_dirs_from_context_root(&project_context_dir(project_dir))
            .into_iter()
            .map(|project_dir| project_dir.join(".active.json")),
    );
    Ok(load_merged_registry(paths))
}

/// Load the active-session registry for a project context root.
#[must_use]
pub(crate) fn load_active_registry_for_context_root(context_root: &Path) -> ActiveRegistry {
    let mut paths = BTreeSet::new();
    if let Some(origin) = load_project_origin(context_root)
        && let Some(project_name) = Path::new(&origin.recorded_from_dir)
            .file_name()
            .and_then(|name| name.to_str())
    {
        paths.insert(
            workspace_sessions_root(&harness_data_root())
                .join(project_name)
                .join(".active.json"),
        );
    }
    paths.extend(
        files::adopted_project_dirs_from_context_root(context_root)
            .into_iter()
            .map(|project_dir| project_dir.join(".active.json")),
    );
    load_merged_registry(paths)
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
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) adopted_session_roots: BTreeMap<String, String>,
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
    let context_root = project_context_dir(project_dir);
    let path = context_root.join(PROJECT_ORIGIN_FILE);
    let previous = load_project_origin(&context_root);
    let origin = build_project_origin_record(project_dir, previous.as_ref());
    write_json_pretty(&path, &origin)
}

/// Record an adopted external session root for later file-backed discovery.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn record_adopted_session_root(
    project_dir: &Path,
    session_id: &str,
    session_root: &Path,
) -> Result<(), CliError> {
    let context_root = project_context_dir(project_dir);
    let path = context_root.join(PROJECT_ORIGIN_FILE);
    let previous = load_project_origin(&context_root);
    let identity = resolve_git_checkout_identity(project_dir);
    let mut origin = ProjectOriginRecord {
        recorded_from_dir: project_dir.to_string_lossy().to_string(),
        repository_root: identity
            .as_ref()
            .map(|value| value.repository_root.display().to_string()),
        checkout_root: identity
            .as_ref()
            .map(|value| value.checkout_root.display().to_string()),
        adopted_session_roots: BTreeMap::from([(
            session_id.to_string(),
            session_root.to_string_lossy().to_string(),
        )]),
        recorded_at: utc_now(),
    };
    origin = merge_project_origin(origin, previous.as_ref());
    origin.adopted_session_roots.insert(
        session_id.to_string(),
        session_root.to_string_lossy().to_string(),
    );
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
    for (session_id, session_root) in &previous.adopted_session_roots {
        origin
            .adopted_session_roots
            .entry(session_id.clone())
            .or_insert_with(|| session_root.clone());
    }
    origin
}

fn build_project_origin_record(
    project_dir: &Path,
    previous: Option<&ProjectOriginRecord>,
) -> ProjectOriginRecord {
    let identity = resolve_git_checkout_identity(project_dir);
    merge_project_origin(
        ProjectOriginRecord {
            recorded_from_dir: project_dir.to_string_lossy().to_string(),
            repository_root: identity
                .as_ref()
                .map(|value| value.repository_root.display().to_string()),
            checkout_root: identity
                .as_ref()
                .map(|value| value.checkout_root.display().to_string()),
            adopted_session_roots: BTreeMap::new(),
            recorded_at: utc_now(),
        },
        previous,
    )
}

fn load_merged_registry(paths: BTreeSet<PathBuf>) -> ActiveRegistry {
    let mut registry = ActiveRegistry::default();
    for path in paths {
        registry.sessions.extend(load_registry_at(&path).sessions);
    }
    registry
}
