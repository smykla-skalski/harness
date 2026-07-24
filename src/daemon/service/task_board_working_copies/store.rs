//! Working-copy registry persistence + Settings-panel list/delete.

use std::fs;

use crate::daemon::state::daemon_root;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::working_copy::runtime::is_reusable_checkout;
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

// Test-only: production writes go through the runtime's locked atomic path
// (`WorkingCopyRuntime::with_registry_mut`); only the injectable GC/list test
// helpers persist a registry directly.
#[cfg(test)]
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
    // tmp-file + rename so a crash mid-write can't leave a truncated registry
    // that fails every subsequent load.
    let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
    fs::write(&tmp, raw).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board working-copy registry write failed: {error}"
        ))
    })?;
    fs::rename(&tmp, &path).map_err(|error| {
        let _ = fs::remove_file(&tmp);
        CliError::from(CliErrorKind::workflow_io(format!(
            "task-board working-copy registry rename failed: {error}"
        )))
    })
}

/// List the working copies the daemon is currently maintaining, projecting
/// each registry row to the Settings/sheet shape (which carries the checkout
/// `path`). A row whose checkout no longer materializes is filtered out so the
/// listing matches what single-item delivery resolves via `obtain` - otherwise
/// the batch sheet would treat a repo as "resolved" that Deliver then no-ops on.
///
/// # Errors
/// Returns `CliError` when the registry file exists but cannot be parsed.
pub async fn list_task_board_working_copies() -> Result<Vec<WorkingCopyListEntry>, CliError> {
    list_from_root(&working_copies_root()).await
}

async fn list_from_root(root: &WorkingCopyRoot) -> Result<Vec<WorkingCopyListEntry>, CliError> {
    let registry = load_registry(root)?;
    let mut listed = Vec::new();
    for (key, entry) in &registry.entries {
        if is_reusable_checkout(&entry.checkout_path).await {
            listed.push(WorkingCopyListEntry::from_registry_entry(key, entry));
        }
    }
    Ok(listed)
}

/// Delete one working copy identified by its `repo_key_segment`. Removes the
/// checkout directory and the registry row under the shared registry lock, then
/// returns the post-delete listing so the Settings panel refreshes without a
/// follow-up round-trip.
///
/// # Errors
/// Returns `CliError` for an empty segment or a registry write failure.
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
    let segment = segment.to_string();
    super::working_copy_runtime()
        .with_registry_mut(move |registry| {
            let matching = registry
                .entries
                .keys()
                .find(|key| key.safe_segment() == segment)
                .cloned();
            if let Some(key) = matching {
                remove_entry(registry, &key);
            }
        })
        .await
        .map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!(
                "task-board working-copy delete registry write failed: {error}"
            ))
            .into()
        })?;
    list_task_board_working_copies().await
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::working_copy::runtime::completion_marker;

    fn seed_row(registry: &mut WorkingCopyRegistry, key: &WorkingCopyKey, path: std::path::PathBuf) {
        registry.insert_or_update(
            key.clone(),
            WorkingCopyRegistryEntry {
                repo_full_name: key.repo_full_name.clone(),
                checkout_path: path,
                size_bytes: 1,
                created_at: chrono::Utc::now(),
                last_used_at: chrono::Utc::now(),
            },
        );
    }

    #[tokio::test]
    async fn list_hides_rows_whose_checkout_is_gone() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = WorkingCopyRoot::new(dir.path().join("working-copies"));

        // A present, reusable checkout: a non-bare repo carrying the completion
        // marker the runtime writes once a checkout finishes.
        let present = WorkingCopyKey::new("owner/present");
        let present_path = present.checkout_path(&root.path);
        std::fs::create_dir_all(&present_path).expect("mkdir");
        gix::init(&present_path).expect("git init");
        std::fs::write(completion_marker(&present_path), b"").expect("marker");

        // A row whose checkout directory was removed out-of-band.
        let missing = WorkingCopyKey::new("owner/missing");
        let missing_path = missing.checkout_path(&root.path);

        let mut registry = WorkingCopyRegistry::default();
        seed_row(&mut registry, &present, present_path);
        seed_row(&mut registry, &missing, missing_path);
        save_registry(&root, &registry).expect("save");

        let listed = list_from_root(&root).await.expect("list");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].repo_full_name, "owner/present");
    }
}
