//! Filesystem layout helpers for the file-to-SQLite Task Board cutover:
//! locating the in-progress migration stage, detecting a completed archive,
//! and computing stage and archive paths.

use std::path::{Path, PathBuf};
use std::process::id as process_id;

use crate::daemon::db::TaskBoardImportMarker;
use crate::errors::{CliError, io_for};
use fs_err as fs;

use super::{ARCHIVE_PREFIX, STAGE_PREFIX, digest_prefix, migration_error};

pub(super) fn find_single_stage(root: &Path) -> Result<Option<PathBuf>, CliError> {
    let Some(parent) = root.parent() else {
        return Ok(None);
    };
    if !parent.is_dir() {
        return Ok(None);
    }
    let mut stages = Vec::new();
    for entry in fs::read_dir(parent)
        .map_err(|error| io_for("read task board migration stages", parent, &error))?
    {
        let path = entry
            .map_err(|error| io_for("read task board migration stage", parent, &error))?
            .path();
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with(STAGE_PREFIX))
        {
            let metadata = fs::symlink_metadata(&path)
                .map_err(|error| io_for("inspect task board migration stage", &path, &error))?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(migration_error(
                    "legacy Task Board migration stage is not a plain directory",
                ));
            }
            stages.push(path);
        }
    }
    stages.sort();
    match stages.len() {
        0 => Ok(None),
        1 => Ok(stages.pop()),
        _ => Err(migration_error(
            "multiple legacy Task Board migration stages require manual recovery",
        )),
    }
}

pub(super) fn has_completed_archive(root: &Path) -> Result<bool, CliError> {
    let Some(parent) = root.parent() else {
        return Ok(false);
    };
    if !parent.is_dir() {
        return Ok(false);
    }
    for entry in
        fs::read_dir(parent).map_err(|error| io_for("read task board archives", parent, &error))?
    {
        let path = entry
            .map_err(|error| io_for("read task board archive", parent, &error))?
            .path();
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with(ARCHIVE_PREFIX))
            && path.is_dir()
        {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn stage_path(root: &Path, digest: &str) -> Result<PathBuf, CliError> {
    let parent = root
        .parent()
        .ok_or_else(|| migration_error("legacy Task Board root has no parent"))?;
    let path = parent.join(format!(
        "{STAGE_PREFIX}{}-{}",
        process_id(),
        digest_prefix(digest)
    ));
    if path.exists() {
        return Err(migration_error(
            "legacy Task Board migration stage already exists",
        ));
    }
    Ok(path)
}

pub(super) fn archive_path(stage: &Path, marker: &TaskBoardImportMarker) -> PathBuf {
    let parent = stage.parent().unwrap_or_else(|| Path::new("."));
    let timestamp = marker
        .imported_at
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect::<String>();
    parent.join(format!(
        "{ARCHIVE_PREFIX}{timestamp}-{}",
        digest_prefix(&marker.source_digest)
    ))
}
