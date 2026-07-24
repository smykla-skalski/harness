//! Working-copy garbage collection.
//!
//! Working copies are a convenience the user can always re-obtain, so the
//! daemon caps their disk use: at startup it drops copies unused past
//! `WORKING_COPY_MAX_AGE_DAYS`, then LRU-evicts until under
//! `WORKING_COPY_DISK_BUDGET_MB`. Delivery bumps `last_used_at`, so an
//! actively-delivered copy is never aged out.

use std::fs;

use crate::errors::CliError;
use crate::task_board::working_copy::{
    WORKING_COPY_DISK_BUDGET_MB, WORKING_COPY_MAX_AGE_DAYS, WorkingCopyKey, WorkingCopyRegistry,
    WorkingCopyRegistryEntry, WorkingCopyRoot,
};

use super::store::{load_registry, save_registry, working_copies_root};

/// One-shot GC pass over the working-copy registry, using the plan defaults.
///
/// # Errors
/// Returns `CliError` when the registry can't be loaded or saved.
pub async fn run_task_board_working_copy_gc() -> Result<WorkingCopyGcReport, CliError> {
    run_task_board_working_copy_gc_with(
        &working_copies_root(),
        chrono::Utc::now(),
        chrono::Duration::days(WORKING_COPY_MAX_AGE_DAYS),
        WORKING_COPY_DISK_BUDGET_MB.saturating_mul(1024 * 1024),
    )
}

/// Same as [`run_task_board_working_copy_gc`] but with the root, `now`,
/// max-age, and disk-budget injected so tests can drive the full flow against
/// a tempdir without touching `daemon_root()`.
///
/// # Errors
/// Returns `CliError` when the registry can't be loaded or saved.
pub fn run_task_board_working_copy_gc_with(
    root: &WorkingCopyRoot,
    now: chrono::DateTime<chrono::Utc>,
    max_age: chrono::Duration,
    max_disk_bytes: u64,
) -> Result<WorkingCopyGcReport, CliError> {
    let mut registry = load_registry(root)?;
    let targets = registry.pick_gc_targets(now, max_age, max_disk_bytes);
    if targets.is_empty() {
        return Ok(WorkingCopyGcReport::default());
    }
    let report = apply_targets(&mut registry, &targets);
    save_registry(root, &registry)?;
    Ok(report)
}

fn apply_targets(registry: &mut WorkingCopyRegistry, targets: &[WorkingCopyKey]) -> WorkingCopyGcReport {
    let mut report = WorkingCopyGcReport {
        targets: targets.len(),
        removed: 0,
        bytes_freed: 0,
    };
    for key in targets {
        let Some(entry) = registry.entries.get(key).cloned() else {
            continue;
        };
        gc_one_entry(registry, key, &entry, &mut report);
    }
    report
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_gc_msg(msg: &str) {
    tracing::warn!(target = "harness::task_board::working_copy", "{msg}");
}

fn gc_one_entry(
    registry: &mut WorkingCopyRegistry,
    key: &WorkingCopyKey,
    entry: &WorkingCopyRegistryEntry,
    report: &mut WorkingCopyGcReport,
) {
    if entry.checkout_path.exists() {
        match fs::remove_dir_all(&entry.checkout_path) {
            Ok(()) => {
                registry.remove(key);
                report.removed += 1;
                report.bytes_freed = report.bytes_freed.saturating_add(entry.size_bytes);
            }
            Err(error) => warn_gc_msg(&format!(
                "working-copy gc: failed to remove directory: path={} error={error}",
                entry.checkout_path.display()
            )),
        }
    } else {
        // Path already gone; removing the registry row is the cleanup.
        registry.remove(key);
        report.removed += 1;
    }
}

/// Summary of one GC pass, returned so callers (tests, startup logging) can
/// assert on the outcome.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkingCopyGcReport {
    pub targets: usize,
    pub removed: usize,
    pub bytes_freed: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn seed(root: &WorkingCopyRoot, key: &WorkingCopyKey, age_days: i64, now: chrono::DateTime<chrono::Utc>) {
        let checkout = key.checkout_path(&root.path);
        std::fs::create_dir_all(&checkout).expect("create checkout dir");
        std::fs::write(checkout.join("marker"), b"x").expect("write marker");
        let mut registry = load_registry(root).expect("load");
        registry.insert_or_update(
            key.clone(),
            WorkingCopyRegistryEntry {
                repo_full_name: key.repo_full_name.clone(),
                checkout_path: checkout,
                size_bytes: 1,
                created_at: now - chrono::Duration::days(age_days),
                last_used_at: now - chrono::Duration::days(age_days),
            },
        );
        save_registry(root, &registry).expect("save");
    }

    #[test]
    fn gc_removes_stale_checkout_directory_and_row() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = WorkingCopyRoot::new(dir.path().join("working-copies"));
        let now = chrono::Utc::now();
        let stale = WorkingCopyKey::new("owner/stale");
        let fresh = WorkingCopyKey::new("owner/fresh");
        seed(&root, &stale, 40, now);
        seed(&root, &fresh, 0, now);
        let stale_path = stale.checkout_path(&root.path);

        let report = run_task_board_working_copy_gc_with(
            &root,
            now,
            chrono::Duration::days(WORKING_COPY_MAX_AGE_DAYS),
            u64::MAX,
        )
        .expect("gc");

        assert_eq!(report.removed, 1);
        assert!(!stale_path.exists());
        let remaining = load_registry(&root).expect("load");
        assert!(remaining.entries.contains_key(&fresh));
        assert!(!remaining.entries.contains_key(&stale));
    }

    #[test]
    fn gc_noop_when_all_fresh_and_under_budget() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = WorkingCopyRoot::new(dir.path().join("working-copies"));
        let now = chrono::Utc::now();
        seed(&root, &WorkingCopyKey::new("owner/fresh"), 0, now);
        let report = run_task_board_working_copy_gc_with(
            &root,
            now,
            chrono::Duration::days(WORKING_COPY_MAX_AGE_DAYS),
            u64::MAX,
        )
        .expect("gc");
        assert_eq!(report, WorkingCopyGcReport::default());
        assert!(!PathBuf::from(root.registry_path()).to_string_lossy().is_empty());
    }
}
