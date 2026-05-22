//! Local-clone registry persistence + Settings-panel list/delete endpoints.

use std::fs;

use crate::daemon::state::daemon_root;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{LocalCloneListEntry, LocalCloneRegistry, LocalCloneRoot};

use super::CLONES_SUBDIR;

pub(super) fn clones_root() -> LocalCloneRoot {
    LocalCloneRoot::new(daemon_root().join(CLONES_SUBDIR))
}

pub(super) fn load_registry(root: &LocalCloneRoot) -> Result<LocalCloneRegistry, CliError> {
    let path = root.registry_path();
    if !path.exists() {
        return Ok(LocalCloneRegistry::default());
    }
    let raw = fs::read_to_string(&path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "reviews clones registry read failed: {error}"
        ))
    })?;
    serde_json::from_str::<LocalCloneRegistry>(&raw).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "reviews clones registry parse failed: {error}"
        ))
        .into()
    })
}

pub(super) fn save_registry(
    root: &LocalCloneRoot,
    registry: &LocalCloneRegistry,
) -> Result<(), CliError> {
    let path = root.registry_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "reviews clones registry parent create failed: {error}"
            ))
        })?;
    }
    let raw = serde_json::to_string_pretty(registry).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "reviews clones registry serialize failed: {error}"
        ))
    })?;
    fs::write(&path, raw).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "reviews clones registry write failed: {error}"
        ))
        .into()
    })
}

/// List the local clones the daemon is currently maintaining.
///
/// Loads `<daemon-root>/reviews/clones/registry.json` and
/// projects each entry to the Settings-panel shape. Returns an empty list
/// when the registry file is absent (no clones yet).
///
/// # Errors
/// Returns `CliError` when the registry file exists but cannot be parsed.
pub async fn list_review_local_clones() -> Result<Vec<LocalCloneListEntry>, CliError> {
    let root = clones_root();
    let registry = load_registry(&root)?;
    Ok(registry
        .entries
        .iter()
        .map(|(key, entry)| LocalCloneListEntry::from_registry_entry(key, entry))
        .collect())
}

/// Delete one local clone identified by its `repo_key_segment` (the
/// "<sha-prefix>__<safe-owner>_<safe-name>" string projected by the
/// registry). Removes the bare clone directory and the registry entry.
/// Returns the post-delete listing so the Settings panel can refresh
/// without a follow-up round-trip.
///
/// # Errors
/// Returns `CliError` for empty segments or filesystem errors during
/// registry persistence.
pub async fn delete_review_local_clone(
    repo_key_segment: &str,
) -> Result<Vec<LocalCloneListEntry>, CliError> {
    let segment = repo_key_segment.trim();
    if segment.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files local-clone delete: repo_key_segment must not be empty",
        )
        .into());
    }
    let root = clones_root();
    let mut registry = load_registry(&root)?;
    let matching_key = registry
        .entries
        .keys()
        .find(|key| key.safe_segment() == segment)
        .cloned();
    if let Some(key) = matching_key {
        if let Some(entry) = registry.remove(&key) {
            if entry.bare_path.exists() {
                if let Err(error) = fs::remove_dir_all(&entry.bare_path) {
                    tracing::warn!(
                        target = "harness::reviews::files",
                        path = ?entry.bare_path,
                        error = %error,
                        "failed to remove local clone directory"
                    );
                }
            }
        }
        save_registry(&root, &registry)?;
    }
    Ok(registry
        .entries
        .iter()
        .map(|(key, entry)| LocalCloneListEntry::from_registry_entry(key, entry))
        .collect())
}
