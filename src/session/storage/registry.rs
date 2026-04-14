use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::{
    project_context_dir, resolve_git_checkout_identity, utc_now, GitCheckoutIdentity,
};

use super::files;

/// Active session registry: maps session IDs to creation timestamps.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct ActiveRegistry {
    #[serde(default)]
    pub(crate) sessions: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ProjectOriginRecord {
    pub(crate) recorded_from_dir: String,
    pub(crate) repository_root: Option<String>,
    pub(crate) checkout_root: Option<String>,
    #[serde(default)]
    pub(crate) is_worktree: bool,
    pub(crate) worktree_name: Option<String>,
    pub(crate) recorded_at: String,
}

/// Register a session ID in the active registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn register_active(project_dir: &Path, session_id: &str) -> Result<(), CliError> {
    files::validate_session_id(session_id)?;
    files::with_lock(project_dir, "active-registry", || {
        let path = files::active_registry_path(project_dir);
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
    files::validate_session_id(session_id)?;
    files::with_lock(project_dir, "active-registry", || {
        let path = files::active_registry_path(project_dir);
        let mut registry = load_active_registry(&path);
        registry.sessions.remove(session_id);
        write_json_pretty(&path, &registry)
    })
}

/// Load the active session registry.
pub(crate) fn load_active_registry_for(project_dir: &Path) -> ActiveRegistry {
    load_active_registry(&files::active_registry_path(project_dir))
}

fn load_active_registry(path: &Path) -> ActiveRegistry {
    read_json_typed::<ActiveRegistry>(path).unwrap_or_default()
}

const PROJECT_ORIGIN_FILE: &str = "project-origin.json";

/// Record the originating project directory in the context root so
/// cross-project discovery can recover it later.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn record_project_origin(project_dir: &Path) -> Result<(), CliError> {
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
        is_worktree: identity
            .as_ref()
            .is_some_and(GitCheckoutIdentity::is_worktree),
        worktree_name: identity.and_then(|value| value.worktree_name().map(ToString::to_string)),
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
    if !origin.is_worktree && previous.is_worktree {
        origin.is_worktree = true;
        origin.worktree_name.clone_from(&previous.worktree_name);
    }
    if origin.worktree_name.is_none() {
        origin.worktree_name.clone_from(&previous.worktree_name);
    }
    origin
}
