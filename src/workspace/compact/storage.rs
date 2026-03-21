use std::borrow::Cow;
use std::path::Path;

use rayon::prelude::*;

use crate::errors::{CliError, io_for};
use crate::infra::io::{read_text, write_json_pretty};
use crate::workspace::{session_scope_key, utc_now};

use super::{
    CompactHandoff, HANDOFF_VERSION, HandoffStatus, compact_history_dir, compact_latest_path,
    history::trim_history,
};

/// Build a compact handoff from the current state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn build_compact_handoff(project_dir: &Path) -> Result<CompactHandoff<'static>, CliError> {
    Ok(CompactHandoff {
        version: HANDOFF_VERSION,
        project_dir: Cow::Owned(project_dir.to_string_lossy().into_owned()),
        created_at: Cow::Owned(utc_now()),
        status: HandoffStatus::Pending,
        source_session_scope: session_scope_key().ok().map(Cow::Owned),
        source_session_id: None,
        transcript_path: None,
        cwd: None,
        trigger: None,
        custom_instructions: None,
        consumed_at: None,
        runner: None,
        create: None,
        fingerprints: vec![],
    })
}

/// Save a compact handoff to the project directory.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn save_compact_handoff(
    project_dir: &Path,
    handoff: &CompactHandoff<'_>,
) -> Result<(), CliError> {
    let latest_path = compact_latest_path(project_dir);
    let history_dir = compact_history_dir(project_dir);
    let history_name = handoff.created_at.replace([':', '.'], "") + ".json";
    let history_path = history_dir.join(history_name);

    write_json_atomic(&latest_path, handoff)?;
    write_json_atomic(&history_path, handoff)?;
    trim_history(&history_dir);

    Ok(())
}

/// Load the latest compact handoff.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_latest_compact_handoff(
    project_dir: &Path,
) -> Result<Option<CompactHandoff<'static>>, CliError> {
    let path = compact_latest_path(project_dir);
    if !path.exists() {
        return Ok(None);
    }
    let text =
        read_text(&path).map_err(|error| -> CliError { io_for("read", &path, &error).into() })?;
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|error| -> CliError { io_for("parse compact handoff at", &path, &error).into() })
}

/// Load a pending (unconsumed) compact handoff, if any.
///
/// # Errors
/// Returns `CliError` if the persisted compact handoff exists but is unreadable
/// or corrupt.
pub fn pending_compact_handoff(
    project_dir: &Path,
) -> Result<Option<CompactHandoff<'static>>, CliError> {
    let handoff = load_latest_compact_handoff(project_dir)?;
    Ok(handoff.filter(|item| item.status == HandoffStatus::Pending))
}

/// Mark a handoff as consumed.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn consume_compact_handoff<'a>(
    project_dir: &Path,
    handoff: CompactHandoff<'a>,
) -> Result<CompactHandoff<'a>, CliError> {
    let consumed = CompactHandoff {
        status: HandoffStatus::Consumed,
        consumed_at: Some(Cow::Owned(utc_now())),
        ..handoff
    };
    write_json_atomic(&compact_latest_path(project_dir), &consumed)?;
    Ok(consumed)
}

/// Check which fingerprints have diverged from disk.
#[must_use]
pub fn verify_fingerprints<'a>(handoff: &'a CompactHandoff<'_>) -> Vec<&'a Path> {
    handoff
        .fingerprints
        .par_iter()
        .filter(|fingerprint| !fingerprint.matches_disk())
        .map(|fingerprint| fingerprint.path.as_path())
        .collect()
}

pub(super) fn write_json_atomic(path: &Path, payload: &CompactHandoff<'_>) -> Result<(), CliError> {
    write_json_pretty(path, payload)
}
