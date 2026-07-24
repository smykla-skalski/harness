//! Working-copy registry persistence + Settings-panel list/delete.

use std::fs;

use crate::daemon::state::daemon_root;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::working_copy::{
    WorkingCopyKey, WorkingCopyListEntry, WorkingCopyRegistry, WorkingCopyRegistryEntry,
    WorkingCopyRoot,
};

use super::WORKING_COPIES_SUBDIR;

pub(super) fn working_copies_root() -> WorkingCopyRoot {
    WorkingCopyRoot::new(daemon_root().join(WORKING_COPIES_SUBDIR))
}

pub(super) fn load_registry(root: &WorkingCopyRoot) -> Result<WorkingCopyRegistry, CliError> {
    let path = root.registry_path();
    if !path.exists() {
        return Ok(WorkingCopyRegistry::default());
    }
    let raw = fs::read_to_string(&path).map_err(|error| {
        CliErrorKind::workflow_io(format!("task-board working-copy registry read failed: {error}"))
    })?;
    serde_json::from_str::<WorkingCopyRegistry>(&raw).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "task-board working-copy registry parse failed: {error}"
        ))
        .into()
    })
}

pub(super) fn save_registry(
    root: &WorkingCopyRoot,
    registry: &WorkingCopyRegistry,
) -> Result<(), CliError> {
    let path = root.registry_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "task-board working-copy registry parent create failed: {error}"
            ))
        })?;
    }
    let raw = serde_json::to_string_pretty(registry).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "task-board working-copy registry serialize failed: {error}"
        ))
    })?;
    fs::write(&path, raw).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board working-copy registry write failed: {error}"
        ))
        .into()
    })
}

fn project(registry: &WorkingCopyRegistry) -> Vec<WorkingCopyListEntry> {
    registry
        .entries
        .iter()
        .map(|(key, entry)| WorkingCopyListEntry::from_registry_entry(key, entry))
        .collect()
}

/// List the working copies the daemon is currently maintaining, projecting
/// each registry row to the Settings/sheet shape (which carries the checkout
/// `path`). Returns an empty list when the registry file is absent.
///
/// # Errors
/// Returns `CliError` when the registry file exists but cannot be parsed.
pub async fn list_task_board_working_copies() -> Result<Vec<WorkingCopyListEntry>, CliError> {
    let root = working_copies_root();
    Ok(project(&load_registry(&root)?))
}

/// Delete one working copy identified by its `repo_key_segment`. Removes the
/// checkout directory and the registry row, then returns the post-delete
/// listing so the Settings panel refreshes without a follow-up round-trip.
///
/// # Errors
/// Returns `CliError` for an empty segment or filesystem errors during
/// registry persistence.
pub async fn delete_task_board_working_copy(
    repo_key_segment: &str,
) -> Result<Vec<WorkingCopyListEntry>, CliError> {
    let segment = repo_key_segment.trim();
    if segment.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "task-board working-copy delete: repo_key_segment must not be empty",
        )
        .into());
    }
    let root = working_copies_root();
    let mut registry = load_registry(&root)?;
    let matching_key = registry
        .entries
        .keys()
        .find(|key| key.safe_segment() == segment)
        .cloned();
    if let Some(key) = matching_key {
        remove_entry(&mut registry, &key);
        save_registry(&root, &registry)?;
    }
    Ok(project(&registry))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_working_copy_msg(msg: &str) {
    tracing::warn!(target = "harness::task_board::working_copy", "{msg}");
}

fn try_remove_checkout_dir(entry: &WorkingCopyRegistryEntry) {
    if !entry.checkout_path.exists() {
        return;
    }
    if let Err(error) = fs::remove_dir_all(&entry.checkout_path) {
        warn_working_copy_msg(&format!(
            "failed to remove working-copy directory: path={} error={error}",
            entry.checkout_path.display()
        ));
    }
}

fn remove_entry(registry: &mut WorkingCopyRegistry, key: &WorkingCopyKey) {
    if let Some(entry) = registry.remove(key) {
        try_remove_checkout_dir(&entry);
    }
}
