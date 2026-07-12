//! One-time file-to-SQLite Task Board cutover.

use std::fs::{File, Metadata, OpenOptions};
use std::io::{ErrorKind, Write as _};
use std::path::{Path, PathBuf};

use crate::daemon::db::{AsyncDaemonDb, TaskBoardImportMarker};
use crate::daemon::state::{self, DaemonManifest, DaemonOwnership, FlockGuard};
use crate::errors::{CliError, CliErrorKind, io_for};
use crate::infra::io::read_json_typed;
use crate::task_board::legacy_import::LegacyTaskBoardSnapshot;
use crate::task_board::{TaskBoardGitRuntimeConfig, default_board_root};
use crate::workspace::utc_now;
use fs_err as fs;

mod stages;
use stages::{archive_path, find_single_stage, has_completed_archive, stage_path};

const LEGACY_SOURCE: &str = "legacy_global_board";
const STAGE_PREFIX: &str = "task-board.migrating-v46-";
const ARCHIVE_PREFIX: &str = "task-board.legacy-v45-";
const SENTINEL: &str = "Harness 46 retired file-backed Task Board storage. Use the daemon API.\n";
const LEGACY_LOCKS: &[&str] = &[
    ".mutation.lock",
    "policy-canvases-v1.json.lock",
    "policy-workflow-runs-v1.json.lock",
    "policy-event-inbox-v1.json.lock",
    "policy-handoff-outbox-v1.json.lock",
    "policy-notification-outbox-v1.json.lock",
    "policy-task-creation-outbox-v1.json.lock",
];

pub(super) async fn migrate_task_board(db: &AsyncDaemonDb) -> Result<(), CliError> {
    let raw_config = state::load_runtime_config_raw()?
        .and_then(|config| config.task_board_git_runtime_config)
        .unwrap_or_default();
    let database_config = raw_config.without_secret_metadata();
    let secret_digest = state::task_board_git_runtime_secret_handoff_digest(&raw_config)?;

    if DaemonOwnership::from_env_or_default() == DaemonOwnership::External {
        db.initialize_empty_task_board(&database_config, secret_digest.as_deref())
            .await?;
        state::remove_migrated_task_board_config_if_safe()?;
        finish_secret_handoff_cleanup(db).await?;
        return Ok(());
    }

    migrate_managed_board(db, &database_config, secret_digest.as_deref()).await?;
    state::remove_migrated_task_board_config_if_safe()?;
    finish_secret_handoff_cleanup(db).await?;
    Ok(())
}

async fn finish_secret_handoff_cleanup(db: &AsyncDaemonDb) -> Result<(), CliError> {
    recover_acknowledging_secret_handoff(db).await?;
    let Some(marker) = db.completed_task_board_secret_handoff().await? else {
        return Ok(());
    };
    let digest = marker
        .secret_handoff_digest
        .as_deref()
        .ok_or_else(|| migration_error("completed Task Board secret handoff has no digest"))?;
    state::remove_migrated_task_board_config_after_ack(digest)?;
    Ok(())
}

async fn recover_acknowledging_secret_handoff(db: &AsyncDaemonDb) -> Result<(), CliError> {
    let Some(marker) = db.pending_task_board_secret_handoff().await? else {
        return Ok(());
    };
    if marker.secret_handoff_phase != "acknowledging" {
        return Ok(());
    }
    let migration_id = marker
        .secret_handoff_id
        .as_deref()
        .ok_or_else(|| migration_error("pending Task Board secret handoff has no migration id"))?;
    let digest = marker
        .secret_handoff_digest
        .as_deref()
        .ok_or_else(|| migration_error("pending Task Board secret handoff has no digest"))?;
    state::remove_migrated_task_board_config_after_ack(digest)?;
    db.complete_task_board_secret_handoff(migration_id).await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "cutover sequencing keeps import, policy, and archive failure boundaries explicit"
)]
async fn migrate_managed_board(
    db: &AsyncDaemonDb,
    runtime_config: &TaskBoardGitRuntimeConfig,
    secret_digest: Option<&str>,
) -> Result<(), CliError> {
    let root = default_board_root();
    if let Some(marker) = db.task_board_import_marker(LEGACY_SOURCE).await? {
        return finalize_existing_import(db, &root, &marker).await;
    }

    reject_legacy_writers()?;
    let prepared = prepare_managed_source(&root)?;
    let snapshot = if prepared.staged {
        LegacyTaskBoardSnapshot::load(&prepared.source)?
    } else {
        LegacyTaskBoardSnapshot::empty()?
    };
    db.import_legacy_task_board(
        &snapshot,
        prepared.staged.then_some(prepared.source.as_path()),
        runtime_config,
        secret_digest,
    )
    .await?;
    import_legacy_policy_workspace(db, &snapshot).await?;

    if prepared.staged {
        let marker = required_marker(db).await?;
        archive_stage(db, &prepared.source, &marker).await?;
    }
    drop(prepared.locks);
    Ok(())
}

struct PreparedSource {
    source: PathBuf,
    staged: bool,
    locks: Vec<FlockGuard>,
}

fn prepare_managed_source(root: &Path) -> Result<PreparedSource, CliError> {
    let root_metadata = path_metadata(root)?;
    if root_metadata
        .as_ref()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(migration_error(
            "legacy Task Board root must not be a symbolic link",
        ));
    }
    let existing_stage = find_single_stage(root)?;
    if root_metadata.as_ref().is_some_and(Metadata::is_dir) {
        if existing_stage.is_some() {
            return Err(migration_error(
                "legacy Task Board root was recreated while a migration stage still exists",
            ));
        }
        LegacyTaskBoardSnapshot::load(root)?;
        let locks = acquire_legacy_locks(root)?;
        let snapshot = LegacyTaskBoardSnapshot::load(root)?;
        let stage = stage_path(root, &snapshot.source_digest)?;
        fs::rename(root, &stage)
            .map_err(|error| io_for("stage legacy task board", root, &error))?;
        ensure_sentinel(root)?;
        return Ok(PreparedSource {
            source: stage,
            staged: true,
            locks,
        });
    }

    if root_metadata.is_some() {
        validate_sentinel(root)?;
        if let Some(stage) = existing_stage {
            return Ok(PreparedSource {
                source: stage,
                staged: true,
                locks: Vec::new(),
            });
        }
        if has_completed_archive(root)? {
            // The global file->SQLite cutover already ran to completion: the
            // sentinel is in place and the migrated data lives in a
            // `legacy-v45-*` archive. A fresh per-lane daemon database reaching
            // this point has nothing to import, so start from an empty board
            // rather than aborting. The archive is left untouched.
            return stage_empty_source(root);
        }
        return Err(migration_error(
            "legacy Task Board sentinel exists without a recoverable migration stage",
        ));
    }

    if let Some(stage) = existing_stage {
        ensure_sentinel(root)?;
        return Ok(PreparedSource {
            source: stage,
            staged: true,
            locks: Vec::new(),
        });
    }

    stage_empty_source(root)
}

fn stage_empty_source(root: &Path) -> Result<PreparedSource, CliError> {
    let empty = LegacyTaskBoardSnapshot::empty()?;
    let stage = stage_path(root, &empty.source_digest)?;
    fs::create_dir(&stage)
        .map_err(|error| io_for("stage empty legacy task board", &stage, &error))?;
    ensure_sentinel(root)?;
    Ok(PreparedSource {
        source: stage,
        staged: true,
        locks: Vec::new(),
    })
}

async fn finalize_existing_import(
    db: &AsyncDaemonDb,
    root: &Path,
    marker: &TaskBoardImportMarker,
) -> Result<(), CliError> {
    let metadata = path_metadata(root)?;
    if metadata.as_ref().is_some_and(Metadata::is_dir) {
        return Err(migration_error(
            "a legacy Task Board directory was recreated after database cutover",
        ));
    }
    if metadata.is_some() {
        validate_sentinel(root)?;
    } else {
        ensure_sentinel(root)?;
    }
    let discovered_stage = find_single_stage(root)?;
    if marker.archived_at.is_some() {
        if discovered_stage.is_some() {
            return Err(migration_error(
                "an unexpected legacy Task Board stage remains after archival",
            ));
        }
        return Ok(());
    }
    let Some(staged_path) = marker.staged_path.as_deref() else {
        if discovered_stage.is_some() {
            return Err(migration_error(
                "legacy Task Board stage exists for an unstaged database import",
            ));
        }
        return Ok(());
    };
    let stage = PathBuf::from(staged_path);
    if discovered_stage
        .as_ref()
        .is_some_and(|found| found != &stage)
    {
        return Err(migration_error(
            "legacy Task Board stage does not match the database import marker",
        ));
    }
    let policy_source = if stage.is_dir() {
        stage.clone()
    } else {
        archive_path(&stage, marker)
    };
    let snapshot = LegacyTaskBoardSnapshot::load(&policy_source)?;
    verify_snapshot_matches_marker(&snapshot, marker)?;
    import_legacy_policy_workspace(db, &snapshot).await?;
    archive_stage(db, &stage, marker).await
}

fn verify_snapshot_matches_marker(
    snapshot: &LegacyTaskBoardSnapshot,
    marker: &TaskBoardImportMarker,
) -> Result<(), CliError> {
    if snapshot.source_digest != marker.source_digest {
        return Err(migration_error(
            "legacy Task Board source changed after its database import",
        ));
    }
    if snapshot.canonical_digest != marker.canonical_model_digest {
        return Err(migration_error(
            "legacy Task Board canonical model changed after its database import",
        ));
    }
    Ok(())
}

async fn import_legacy_policy_workspace(
    db: &AsyncDaemonDb,
    snapshot: &LegacyTaskBoardSnapshot,
) -> Result<(), CliError> {
    let Some(workspace) = snapshot.policy_workspace.as_ref() else {
        return Ok(());
    };
    if db.load_policy_workspace().await?.is_some() {
        return Ok(());
    }
    db.replace_policy_workspace(workspace).await?;
    if db.load_policy_workspace().await?.as_ref() != Some(workspace) {
        return Err(migration_error(
            "legacy policy workspace failed database read-back verification",
        ));
    }
    Ok(())
}

async fn archive_stage(
    db: &AsyncDaemonDb,
    stage: &Path,
    marker: &TaskBoardImportMarker,
) -> Result<(), CliError> {
    let archive = marker
        .archive_path
        .as_deref()
        .map_or_else(|| archive_path(stage, marker), PathBuf::from);
    if stage.is_dir() {
        if archive.exists() {
            return Err(migration_error(
                "both legacy Task Board migration stage and archive exist",
            ));
        }
        fs::rename(stage, &archive)
            .map_err(|error| io_for("archive legacy task board", stage, &error))?;
        sync_parent(&archive)?;
    } else if !archive.is_dir() {
        return Err(migration_error(
            "database import completed but its legacy Task Board stage is missing",
        ));
    }
    db.mark_task_board_archive_complete(LEGACY_SOURCE, &archive, &utc_now())
        .await
}

async fn required_marker(db: &AsyncDaemonDb) -> Result<TaskBoardImportMarker, CliError> {
    db.task_board_import_marker(LEGACY_SOURCE)
        .await?
        .ok_or_else(|| migration_error("legacy Task Board import marker was not recorded"))
}

fn acquire_legacy_locks(root: &Path) -> Result<Vec<FlockGuard>, CliError> {
    LEGACY_LOCKS
        .iter()
        .map(|name| state::acquire_flock_exclusive(&root.join(name), "task board migration"))
        .collect()
}

fn reject_legacy_writers() -> Result<(), CliError> {
    let legacy_lock = state::base_daemon_dir().join(state::DAEMON_LOCK_FILE);
    if state::flock_is_held_at(&legacy_lock) {
        return Err(migration_error(
            "stop the legacy Harness daemon before migrating Task Board data",
        ));
    }
    let external_root = state::daemon_root_for_ownership(DaemonOwnership::External);
    let external_lock = external_root.join(state::DAEMON_LOCK_FILE);
    if !state::flock_is_held_at(&external_lock) {
        return Ok(());
    }
    let manifest_path = external_root.join("manifest.json");
    let compatible = read_json_typed::<DaemonManifest>(&manifest_path)
        .ok()
        .is_some_and(|manifest| version_major(&manifest.version) >= 46);
    if compatible {
        return Ok(());
    }
    Err(migration_error(
        "stop the pre-v46 external Harness daemon before migrating Task Board data",
    ))
}

fn ensure_sentinel(root: &Path) -> Result<(), CliError> {
    if path_metadata(root)?.is_some() {
        return validate_sentinel(root);
    }
    if let Some(parent) = root.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| io_for("create task board parent", parent, &error))?;
    }
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(root)
        .map_err(|error| io_for("create task board incompatibility sentinel", root, &error))?;
    file.write_all(SENTINEL.as_bytes())
        .map_err(|error| io_for("write task board incompatibility sentinel", root, &error))?;
    file.sync_all()
        .map_err(|error| io_for("sync task board incompatibility sentinel", root, &error))?;
    sync_parent(root)
}

fn validate_sentinel(root: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(root)
        .map_err(|error| io_for("inspect task board incompatibility sentinel", root, &error))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(migration_error(
            "legacy Task Board cutover sentinel is not a plain file",
        ));
    }
    let contents = fs::read_to_string(root)
        .map_err(|error| io_for("read task board incompatibility sentinel", root, &error))?;
    if contents != SENTINEL {
        return Err(migration_error(
            "legacy Task Board cutover sentinel has unexpected contents",
        ));
    }
    Ok(())
}

fn path_metadata(path: &Path) -> Result<Option<Metadata>, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_for("inspect legacy task board path", path, &error).into()),
    }
}

fn sync_parent(path: &Path) -> Result<(), CliError> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    File::open(parent)
        .and_then(|file| file.sync_all())
        .map_err(|error| io_for("sync task board parent", parent, &error))?;
    Ok(())
}

fn version_major(version: &str) -> u64 {
    version
        .split('.')
        .next()
        .and_then(|part| part.parse().ok())
        .unwrap_or(0)
}

fn digest_prefix(digest: &str) -> &str {
    digest.get(..12).unwrap_or(digest)
}

fn migration_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}

#[cfg(test)]
mod tests;
