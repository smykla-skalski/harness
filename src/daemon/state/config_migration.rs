//! Crash-safe retirement of the legacy Task Board runtime-config envelope.

use std::fs::File;

use sha2::{Digest, Sha256};

use super::config::{DaemonRuntimeConfig, load_runtime_config_raw};
use super::config_path;
use crate::errors::{CliError, CliErrorKind, io_for};
use crate::infra::io::write_json_pretty;
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::task_board::TaskBoardGitRuntimeConfig;

/// Compute the stable digest carried by the database-backed secret handoff.
/// `None` means the legacy envelope contains no plaintext secret material.
pub(crate) fn task_board_git_runtime_secret_handoff_digest(
    config: &TaskBoardGitRuntimeConfig,
) -> Result<Option<String>, CliError> {
    if !config.contains_plaintext_secrets() {
        return Ok(None);
    }
    let bytes = serde_json::to_vec(config).map_err(|error| {
        CliErrorKind::workflow_serialize(format!(
            "serialize pending Task Board secret migration: {error}"
        ))
    })?;
    Ok(Some(hex::encode(Sha256::digest(bytes))))
}

/// Remove non-secret legacy Task Board config after `SQLite` owns its values.
pub(crate) fn remove_migrated_task_board_config_if_safe() -> Result<bool, CliError> {
    with_runtime_config_lock(remove_non_secret_envelope)
}

fn remove_non_secret_envelope() -> Result<bool, CliError> {
    let Some(mut config) = load_runtime_config_raw()? else {
        return Ok(false);
    };
    let Some(task_board) = config.task_board_git_runtime_config.as_ref() else {
        return Ok(false);
    };
    if task_board.contains_plaintext_secrets() {
        return Ok(false);
    }
    config.task_board_git_runtime_config = None;
    write_runtime_config_durable(&config)?;
    Ok(true)
}

/// Remove an acknowledged legacy envelope only when its plaintext still
/// matches the digest that the secure-store client persisted.
pub(crate) fn remove_migrated_task_board_config_after_ack(
    expected_digest: &str,
) -> Result<bool, CliError> {
    with_runtime_config_lock(|| remove_acknowledged_envelope(expected_digest))
}

fn remove_acknowledged_envelope(expected_digest: &str) -> Result<bool, CliError> {
    let Some(mut config) = load_runtime_config_raw()? else {
        return Ok(false);
    };
    let Some(task_board) = config.task_board_git_runtime_config.as_ref() else {
        return Ok(false);
    };
    let actual_digest = task_board_git_runtime_secret_handoff_digest(task_board)?;
    if actual_digest.as_deref() != Some(expected_digest) {
        return Err(CliErrorKind::workflow_parse(
            "acknowledged Task Board secret payload changed before cleanup",
        )
        .into());
    }
    config.task_board_git_runtime_config = None;
    write_runtime_config_durable(&config)?;
    Ok(true)
}

pub(super) fn with_runtime_config_lock<T>(
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let path = config_path().with_extension("json.lock");
    with_exclusive_flock(
        &path,
        FlockErrorContext::new("daemon runtime config"),
        action,
    )
}

pub(super) fn write_runtime_config_durable(config: &DaemonRuntimeConfig) -> Result<(), CliError> {
    let path = config_path();
    write_json_pretty(&path, config)?;
    File::open(&path)
        .and_then(|file| file.sync_all())
        .map_err(|error| io_for("sync migrated daemon runtime config", &path, &error))?;
    if let Some(parent) = path.parent() {
        File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|error| io_for("sync daemon runtime config parent", parent, &error))?;
    }
    Ok(())
}
