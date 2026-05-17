use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;

use super::locks::daemon_lock_is_held_at;
use super::ownership::DaemonOwnership;
use super::paths::{base_daemon_dir, daemon_root_for_ownership};
use super::{DAEMON_LOCK_FILE, DaemonManifest, MANIFEST_LOCK_FILE};

/// Files that exist for lifecycle bookkeeping and should not be moved into
/// the new ownership subtree. Locks tie to the legacy parent directory and
/// are meaningless once orphaned; the new daemon will recreate its own.
const SKIPPED_LEGACY_ENTRIES: &[&str] = &[
    DAEMON_LOCK_FILE,
    MANIFEST_LOCK_FILE,
    "managed",
    "external",
    "bridge.lock",
];

/// Outcome of a single migration attempt. Useful for logging and tests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationDecision {
    /// New ownership subtree already exists; nothing to do.
    AlreadyMigrated,
    /// No legacy manifest at the parent path; nothing to migrate.
    NoLegacyState,
    /// Legacy state exists but the legacy daemon is still running. Skipped to
    /// avoid pulling state out from under a live process.
    LegacyDaemonAlive,
    /// Legacy manifest cannot be parsed. Migration cannot proceed safely.
    UnreadableLegacyManifest,
    /// Inferred ownership of legacy state does not match this process. The
    /// other side will pick it up the next time it starts.
    OwnershipMismatch {
        inferred: DaemonOwnership,
        current: DaemonOwnership,
    },
    /// Successfully moved `count` entries into the new ownership subtree.
    Migrated { count: usize },
}

/// Captured I/O for a single migration run, mostly so tests can assert on
/// what was moved without poking the filesystem layout themselves.
#[derive(Debug, Clone)]
pub struct LegacyDaemonRootMigration {
    pub decision: MigrationDecision,
    pub from: PathBuf,
    pub to: PathBuf,
    pub moved: Vec<PathBuf>,
}

/// Run the one-shot migration for managed-mode startup. Idempotent: returns
/// `AlreadyMigrated` after the first successful pass and `NoLegacyState` on
/// fresh installs.
///
/// # Errors
/// Returns [`CliError`] only on filesystem failures encountered during the
/// move itself. All other reasons to skip migration return as
/// [`MigrationDecision`] variants embedded in the success result.
pub fn migrate_legacy_daemon_root_for_current_process()
-> Result<LegacyDaemonRootMigration, CliError> {
    migrate_legacy_daemon_root(DaemonOwnership::from_env_or_default())
}

pub(crate) fn migrate_legacy_daemon_root(
    current: DaemonOwnership,
) -> Result<LegacyDaemonRootMigration, CliError> {
    let parent = base_daemon_dir();
    let target = daemon_root_for_ownership(current);
    migrate_legacy_daemon_root_at(&parent, &target, current)
}

/// Run migration with explicit parent and target paths. Useful when the
/// caller computes paths outside the env-driven default resolver (notably
/// `harness daemon dev`, which falls back to its own app group default).
///
/// # Errors
/// Returns [`CliError`] only on filesystem failures encountered during the
/// move itself.
pub fn migrate_legacy_daemon_root_at(
    parent: &Path,
    target: &Path,
    current: DaemonOwnership,
) -> Result<LegacyDaemonRootMigration, CliError> {
    let mut report = LegacyDaemonRootMigration {
        decision: MigrationDecision::NoLegacyState,
        from: parent.to_path_buf(),
        to: target.to_path_buf(),
        moved: Vec::new(),
    };

    if target.is_dir() {
        report.decision = MigrationDecision::AlreadyMigrated;
        return Ok(report);
    }

    let legacy_manifest = parent.join("manifest.json");
    if !legacy_manifest.is_file() {
        return Ok(report);
    }

    let legacy_lock = parent.join(DAEMON_LOCK_FILE);
    if legacy_lock.exists() && daemon_lock_is_held_at(&legacy_lock) {
        report.decision = MigrationDecision::LegacyDaemonAlive;
        return Ok(report);
    }

    let manifest: DaemonManifest = if let Ok(manifest) = read_json_typed(&legacy_manifest) {
        manifest
    } else {
        report.decision = MigrationDecision::UnreadableLegacyManifest;
        return Ok(report);
    };

    let inferred = infer_legacy_ownership(&manifest);
    if inferred != current {
        report.decision = MigrationDecision::OwnershipMismatch { inferred, current };
        return Ok(report);
    }

    fs_err::create_dir_all(target)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ownership subtree: {error}")))?;

    let mut moved = Vec::new();
    for entry in fs_err::read_dir(parent)
        .map_err(|error| CliErrorKind::workflow_io(format!("read legacy daemon root: {error}")))?
    {
        let entry = entry.map_err(|error| {
            CliErrorKind::workflow_io(format!("iterate legacy daemon root: {error}"))
        })?;
        let name = entry.file_name();
        if should_skip_entry(&name) {
            continue;
        }
        let from = entry.path();
        let to = target.join(&name);
        fs_err::rename(&from, &to).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "migrate legacy daemon entry {} -> {}: {error}",
                from.display(),
                to.display()
            ))
        })?;
        moved.push(to);
    }

    report.decision = MigrationDecision::Migrated { count: moved.len() };
    report.moved = moved;
    Ok(report)
}

fn should_skip_entry(name: &OsStr) -> bool {
    let Some(name_str) = name.to_str() else {
        return true;
    };
    SKIPPED_LEGACY_ENTRIES.contains(&name_str)
}

/// Heuristic for which ownership wrote the pre-coexistence manifest. Bundled
/// daemons live inside `<App.app>/Contents/Helpers/`; everything else (cargo
/// targets, mise installs, hand-built binaries) is treated as external.
///
/// Without `binary_stamp` we default to managed so the historical case
/// (SMAppService-only installs) still migrates cleanly.
pub(crate) fn infer_legacy_ownership(manifest: &DaemonManifest) -> DaemonOwnership {
    let Some(stamp) = manifest.binary_stamp.as_ref() else {
        return DaemonOwnership::Managed;
    };
    if stamp.helper_path.contains("/.app/Contents/Helpers/")
        || stamp.helper_path.contains(".app/Contents/Helpers/")
    {
        DaemonOwnership::Managed
    } else {
        DaemonOwnership::External
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::state::{DaemonBinaryStamp, HostBridgeManifest};
    use std::fs;
    use tempfile::TempDir;

    fn manifest_with_helper(path: &str) -> DaemonManifest {
        DaemonManifest {
            version: "0.0.0-test".into(),
            pid: 1,
            endpoint: "http://127.0.0.1:0".into(),
            started_at: String::new(),
            token_path: String::new(),
            sandboxed: false,
            host_bridge: HostBridgeManifest::default(),
            revision: 1,
            updated_at: String::new(),
            binary_stamp: Some(DaemonBinaryStamp {
                helper_path: path.to_string(),
                device_identifier: 0,
                inode: 0,
                file_size: 0,
                modification_time_interval_since_1970: 0.0,
            }),
            ownership: DaemonOwnership::default(),
        }
    }

    fn write_legacy_layout(parent: &Path, helper_path: &str) {
        fs::create_dir_all(parent).unwrap();
        let manifest = manifest_with_helper(helper_path);
        let json = serde_json::to_string_pretty(&manifest).unwrap();
        fs::write(parent.join("manifest.json"), json).unwrap();
        fs::write(parent.join("auth-token"), "deadbeef").unwrap();
        fs::write(parent.join("harness.db"), b"sqlite3 stub").unwrap();
        fs::write(parent.join("daemon.lock"), b"").unwrap();
    }

    #[test]
    fn infers_managed_when_helper_lives_under_app_bundle() {
        let manifest =
            manifest_with_helper("/Applications/Harness Monitor.app/Contents/Helpers/harness");
        assert_eq!(infer_legacy_ownership(&manifest), DaemonOwnership::Managed);
    }

    #[test]
    fn infers_external_for_cargo_target() {
        let manifest = manifest_with_helper("/Users/bart/repo/target/debug/harness");
        assert_eq!(infer_legacy_ownership(&manifest), DaemonOwnership::External);
    }

    #[test]
    fn infers_managed_when_binary_stamp_missing() {
        let mut manifest = manifest_with_helper("ignored");
        manifest.binary_stamp = None;
        assert_eq!(infer_legacy_ownership(&manifest), DaemonOwnership::Managed);
    }

    #[test]
    fn skips_when_target_already_exists() {
        let tmp = TempDir::new().unwrap();
        let parent = tmp.path();
        let target = parent.join("managed");
        fs::create_dir_all(&target).unwrap();
        write_legacy_layout(parent, "/Applications/X.app/Contents/Helpers/harness");

        let report =
            migrate_legacy_daemon_root_at(parent, &target, DaemonOwnership::Managed).unwrap();

        assert_eq!(report.decision, MigrationDecision::AlreadyMigrated);
        assert!(parent.join("manifest.json").exists());
    }

    #[test]
    fn skips_when_no_legacy_manifest_present() {
        let tmp = TempDir::new().unwrap();
        let parent = tmp.path();
        let target = parent.join("managed");

        let report =
            migrate_legacy_daemon_root_at(parent, &target, DaemonOwnership::Managed).unwrap();

        assert_eq!(report.decision, MigrationDecision::NoLegacyState);
    }

    #[test]
    fn skips_when_inferred_ownership_does_not_match_current() {
        let tmp = TempDir::new().unwrap();
        let parent = tmp.path();
        let target = parent.join("external");
        write_legacy_layout(parent, "/Applications/X.app/Contents/Helpers/harness");

        let report =
            migrate_legacy_daemon_root_at(parent, &target, DaemonOwnership::External).unwrap();

        assert_eq!(
            report.decision,
            MigrationDecision::OwnershipMismatch {
                inferred: DaemonOwnership::Managed,
                current: DaemonOwnership::External,
            }
        );
        assert!(
            parent.join("manifest.json").exists(),
            "untouched on mismatch"
        );
    }

    #[test]
    fn moves_non_lock_entries_into_target() {
        let tmp = TempDir::new().unwrap();
        let parent = tmp.path();
        let target = parent.join("managed");
        write_legacy_layout(parent, "/Applications/X.app/Contents/Helpers/harness");

        let report =
            migrate_legacy_daemon_root_at(parent, &target, DaemonOwnership::Managed).unwrap();

        assert!(matches!(
            report.decision,
            MigrationDecision::Migrated { count: 3 }
        ));
        assert!(target.join("manifest.json").is_file());
        assert!(target.join("auth-token").is_file());
        assert!(target.join("harness.db").is_file());
        assert!(!parent.join("manifest.json").exists());
        assert!(
            parent.join("daemon.lock").exists(),
            "lock file is left behind"
        );
    }

    #[test]
    fn returns_unreadable_when_legacy_manifest_is_garbage() {
        let tmp = TempDir::new().unwrap();
        let parent = tmp.path();
        let target = parent.join("managed");
        fs::create_dir_all(parent).unwrap();
        fs::write(parent.join("manifest.json"), "not json").unwrap();

        let report =
            migrate_legacy_daemon_root_at(parent, &target, DaemonOwnership::Managed).unwrap();

        assert_eq!(report.decision, MigrationDecision::UnreadableLegacyManifest);
    }
}
