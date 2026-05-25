//! Local-clone garbage collection.

use std::fs;

use crate::errors::CliError;
use crate::reviews::{LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey};

use super::clones::{clones_root, load_registry, save_registry};

/// One-shot garbage collection pass over the local-clone registry.
///
/// Plan §A.5 calls for the daemon to drop stale + over-budget clones at
/// startup so disk usage stays bounded. The selector ([`LocalCloneRegistry::pick_gc_targets`])
/// already encodes the two-pass policy: drop entries whose `last_used_at`
/// is older than `max_age`, then evict LRU entries until total size is
/// under `max_disk_bytes`. This wrapper materializes the targets:
///
/// 1. Load registry from `<root>/registry.json`.
/// 2. Ask the selector for entries to drop, using the plan defaults
///    (`LOCAL_CLONE_MAX_AGE_DAYS`, `LOCAL_CLONE_DISK_BUDGET_MB`).
/// 3. For each target: remove the registry row + delete the bare clone
///    directory.
/// 4. Persist the trimmed registry.
///
/// Best-effort: per-entry filesystem failures are logged via `tracing::warn`
/// but don't abort the GC pass. The registry write-back is required; an
/// IO error there is surfaced as a `CliError`.
///
/// # Errors
/// Returns `CliError` when the registry can't be loaded or saved.
pub async fn run_local_clone_gc() -> Result<GcReport, CliError> {
    use crate::reviews::files::local_clone::{
        LOCAL_CLONE_DISK_BUDGET_MB, LOCAL_CLONE_MAX_AGE_DAYS,
    };
    run_local_clone_gc_with(
        &clones_root(),
        chrono::Utc::now(),
        chrono::Duration::days(LOCAL_CLONE_MAX_AGE_DAYS),
        LOCAL_CLONE_DISK_BUDGET_MB.saturating_mul(1024 * 1024),
    )
}

/// Same as [`run_local_clone_gc`] but with the root, `now`, max-age, and
/// disk-budget injected. Lets tests exercise the full flow against a
/// tempdir without monkeying with `daemon_root()`.
///
/// # Errors
/// Returns `CliError` when the registry can't be loaded or saved.
pub fn run_local_clone_gc_with(
    root: &LocalCloneRoot,
    now: chrono::DateTime<chrono::Utc>,
    max_age: chrono::Duration,
    max_disk_bytes: u64,
) -> Result<GcReport, CliError> {
    let mut registry = load_registry(root)?;
    let targets = registry.pick_gc_targets(now, max_age, max_disk_bytes);
    if targets.is_empty() {
        return Ok(GcReport::default());
    }
    let report = apply_local_clone_gc_targets(&mut registry, &targets);
    save_registry(root, &registry)?;
    log_gc_report(&report);
    Ok(report)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_gc_msg(msg: &str) {
    tracing::warn!(target = "harness::reviews::files", "{msg}");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn info_gc_msg(msg: &str) {
    tracing::info!(target = "harness::reviews::files", "{msg}");
}

fn log_gc_report(report: &GcReport) {
    info_gc_msg(&format!(
        "local-clone gc completed: targets={} removed={} bytes_freed={}",
        report.targets, report.removed, report.bytes_freed
    ));
}

pub(super) fn apply_local_clone_gc_targets(
    registry: &mut LocalCloneRegistry,
    targets: &[RepoKey],
) -> GcReport {
    let mut report = GcReport {
        targets: targets.len(),
        bytes_freed: 0,
        removed: 0,
    };
    for key in targets {
        let Some(entry) = registry.entries.get(key).cloned() else {
            continue;
        };
        gc_one_entry(registry, key, &entry, &mut report);
    }
    report
}

fn remove_entry_path(
    registry: &mut LocalCloneRegistry,
    key: &RepoKey,
    entry: &RegistryEntry,
    report: &mut GcReport,
) {
    match fs::remove_dir_all(&entry.bare_path) {
        Ok(()) => {
            registry.remove(key);
            report.removed += 1;
            report.bytes_freed = report.bytes_freed.saturating_add(entry.size_bytes);
        }
        Err(error) => warn_gc_msg(&format!(
            "local-clone gc: failed to remove bare clone directory: path={} error={error}",
            entry.bare_path.display()
        )),
    }
}

fn gc_one_entry(
    registry: &mut LocalCloneRegistry,
    key: &RepoKey,
    entry: &RegistryEntry,
    report: &mut GcReport,
) {
    if entry.bare_path.exists() {
        remove_entry_path(registry, key, entry, report);
    } else {
        // Entry pointed at a path that no longer exists. Removing the
        // registry row is the cleanup.
        registry.remove(key);
        report.removed += 1;
    }
}

/// Summary of one GC pass. Returned by [`run_local_clone_gc`] so callers
/// (tests, observability hooks) can assert on the outcome.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GcReport {
    /// How many registry entries the selector flagged for removal.
    pub targets: usize,
    /// How many bare clone directories were actually removed from disk.
    pub removed: usize,
    /// Sum of `size_bytes` across successfully-removed entries.
    pub bytes_freed: u64,
}
