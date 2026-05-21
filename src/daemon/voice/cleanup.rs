use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use fs_err as fs;

use crate::errors::{CliError, CliErrorKind};

use super::{VOICE_SESSION_TTL_SECS, VoiceSessionRecord, read_record_from_path, voice_root};

pub(super) fn cleanup_abandoned_sessions_at(now: &DateTime<Utc>) -> Result<(), CliError> {
    for dir in voice_session_dirs()? {
        if voice_session_has_expired(&dir, now)? {
            remove_session_dir(&dir)?;
        }
    }
    Ok(())
}

fn voice_session_dirs() -> Result<Vec<PathBuf>, CliError> {
    let root = voice_root();
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut dirs = Vec::new();
    for entry in fs::read_dir(&root).map_err(|error| {
        CliErrorKind::workflow_io(format!("read voice root {}: {error}", root.display()))
    })? {
        let entry = entry.map_err(|error| {
            CliErrorKind::workflow_io(format!("read voice root entry {}: {error}", root.display()))
        })?;
        let path = entry.path();
        if path.is_dir() {
            dirs.push(path);
        }
    }
    Ok(dirs)
}

fn voice_session_has_expired(dir: &Path, now: &DateTime<Utc>) -> Result<bool, CliError> {
    let path = dir.join("session.json");
    let Some(record) = read_record_from_path(&path)? else {
        return Ok(true);
    };
    Ok(
        voice_session_last_activity(&record).is_none_or(|last_activity| {
            now.signed_duration_since(last_activity)
                >= ChronoDuration::seconds(VOICE_SESSION_TTL_SECS)
        }),
    )
}

fn voice_session_last_activity(record: &VoiceSessionRecord) -> Option<DateTime<Utc>> {
    let timestamp = record.updated_at.as_deref().unwrap_or(&record.created_at);
    DateTime::parse_from_rfc3339(timestamp).ok().map(Into::into)
}

pub(super) fn remove_session_dir(path: &Path) -> Result<(), CliError> {
    if path.exists() {
        fs::remove_dir_all(path).map_err(|error| {
            CliErrorKind::workflow_io(format!("remove voice session {}: {error}", path.display()))
        })?;
    }
    Ok(())
}
