use std::io::{ErrorKind, Write as _};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use fs_err as fs;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::protocol::{
    VoiceAudioChunkRequest, VoiceProcessingSink, VoiceSessionFinishReason,
    VoiceSessionFinishRequest, VoiceSessionMutationResponse, VoiceSessionStartRequest,
    VoiceSessionStartResponse, VoiceTranscriptUpdateRequest,
};
use super::state;

const MAX_AUDIO_CHUNK_BYTES: usize = 1_048_576;
const VOICE_SESSION_TTL_SECS: i64 = 15 * 60;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct VoiceSessionRecord {
    voice_session_id: String,
    harness_session_id: String,
    actor: String,
    locale_identifier: String,
    accepted_sinks: Vec<VoiceProcessingSink>,
    route_target: super::protocol::VoiceRouteTarget,
    requires_confirmation: bool,
    remote_processor_url: Option<String>,
    created_at: String,
    #[serde(default)]
    updated_at: Option<String>,
    last_sequence: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredVoiceChunk {
    sequence: u64,
    format: super::protocol::VoiceAudioFormatDescriptor,
    frame_count: usize,
    started_at_seconds: f64,
    duration_seconds: f64,
    byte_count: usize,
    actor: String,
    recorded_at: String,
}

/// Start a session-scoped voice-processing record.
///
/// # Errors
/// Returns `CliError` when the sink request is invalid or the metadata cannot be persisted.
pub fn start_session(
    harness_session_id: &str,
    request: &VoiceSessionStartRequest,
) -> Result<VoiceSessionStartResponse, CliError> {
    cleanup_abandoned_sessions()?;
    let voice_session_id = format!("voice-{}", Uuid::new_v4());
    let accepted_sinks = accepted_sinks(request)?;
    let now = utc_now();
    let record = VoiceSessionRecord {
        voice_session_id: voice_session_id.clone(),
        harness_session_id: harness_session_id.to_string(),
        actor: request.actor.clone(),
        locale_identifier: request.locale_identifier.clone(),
        accepted_sinks: accepted_sinks.clone(),
        route_target: request.route_target.clone(),
        requires_confirmation: request.requires_confirmation,
        remote_processor_url: request.remote_processor_url.clone(),
        created_at: now.clone(),
        updated_at: Some(now),
        last_sequence: 0,
    };

    let dir = session_dir(&voice_session_id);
    fs::create_dir_all(&dir).map_err(|error| {
        CliErrorKind::workflow_io(format!("create voice session directory: {error}"))
    })?;
    if let Err(error) = write_record(&record) {
        let _ = remove_session_dir(&dir);
        return Err(error);
    }

    Ok(VoiceSessionStartResponse {
        voice_session_id,
        accepted_sinks,
        status: "recording".into(),
    })
}

/// Persist and optionally forward a live audio chunk.
///
/// # Errors
/// Returns `CliError` for invalid ordering, oversized payloads, decode failures, or sink failures.
pub async fn append_audio_chunk(
    voice_session_id: &str,
    request: &VoiceAudioChunkRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    cleanup_session_after_error(
        voice_session_id,
        append_audio_chunk_inner(voice_session_id, request).await,
    )
}

async fn append_audio_chunk_inner(
    voice_session_id: &str,
    request: &VoiceAudioChunkRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    let mut record = read_record(voice_session_id)?;
    if request.sequence != record.last_sequence + 1 {
        return Err(CliErrorKind::workflow_parse(format!(
            "voice chunk sequence out of order: expected {}, got {}",
            record.last_sequence + 1,
            request.sequence
        ))
        .into());
    }

    let bytes = STANDARD.decode(&request.audio_base64).map_err(|error| {
        CliErrorKind::workflow_parse(format!("decode voice audio chunk: {error}"))
    })?;
    if bytes.len() > MAX_AUDIO_CHUNK_BYTES {
        return Err(CliErrorKind::workflow_parse(format!(
            "voice audio chunk exceeds {MAX_AUDIO_CHUNK_BYTES} bytes"
        ))
        .into());
    }

    append_chunk_bytes(voice_session_id, &bytes)?;
    append_chunk_metadata(
        voice_session_id,
        &StoredVoiceChunk {
            sequence: request.sequence,
            format: request.format.clone(),
            frame_count: request.frame_count,
            started_at_seconds: request.started_at_seconds,
            duration_seconds: request.duration_seconds,
            byte_count: bytes.len(),
            actor: request.actor.clone(),
            recorded_at: utc_now(),
        },
    )?;

    record.last_sequence = request.sequence;
    record.updated_at = Some(utc_now());
    write_record(&record)?;

    if record
        .accepted_sinks
        .contains(&VoiceProcessingSink::RemoteProcessor)
    {
        forward_chunk_to_remote(&record, request).await?;
    }

    Ok(VoiceSessionMutationResponse {
        voice_session_id: voice_session_id.to_string(),
        status: "recording".into(),
    })
}

/// Persist a live transcript update for the voice session.
///
/// # Errors
/// Returns `CliError` when the transcript file cannot be updated.
pub fn append_transcript(
    voice_session_id: &str,
    request: &VoiceTranscriptUpdateRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    cleanup_session_after_error(
        voice_session_id,
        append_transcript_inner(voice_session_id, request),
    )
}

fn append_transcript_inner(
    voice_session_id: &str,
    request: &VoiceTranscriptUpdateRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    let mut record = read_record(voice_session_id)?;
    append_json_line(&transcript_path(voice_session_id), request)?;
    record.updated_at = Some(utc_now());
    write_record(&record)?;
    Ok(VoiceSessionMutationResponse {
        voice_session_id: voice_session_id.to_string(),
        status: "recording".into(),
    })
}

/// Finish or cancel a voice session and clean up transient audio data.
///
/// # Errors
/// Returns `CliError` when cleanup fails.
pub fn finish_session(
    voice_session_id: &str,
    request: &VoiceSessionFinishRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    let _record = read_record(voice_session_id)?;
    let status = match request.reason {
        VoiceSessionFinishReason::Completed => "completed",
        VoiceSessionFinishReason::Cancelled => "cancelled",
    };
    remove_session_dir(&session_dir(voice_session_id))?;
    Ok(VoiceSessionMutationResponse {
        voice_session_id: voice_session_id.to_string(),
        status: status.into(),
    })
}

/// Remove abandoned voice-session artifacts from prior crashed or disconnected flows.
///
/// # Errors
/// Returns `CliError` when cleanup cannot enumerate or delete session directories.
pub fn cleanup_abandoned_sessions() -> Result<(), CliError> {
    cleanup_abandoned_sessions_at(&Utc::now())
}

fn accepted_sinks(
    request: &VoiceSessionStartRequest,
) -> Result<Vec<VoiceProcessingSink>, CliError> {
    if request.requested_sinks.is_empty() {
        return Ok(vec![VoiceProcessingSink::LocalDaemon]);
    }

    let mut accepted = Vec::new();
    for sink in &request.requested_sinks {
        match sink {
            VoiceProcessingSink::LocalDaemon | VoiceProcessingSink::AgentBridge => {
                if !accepted.contains(sink) {
                    accepted.push(*sink);
                }
            }
            VoiceProcessingSink::RemoteProcessor => {
                let Some(url) = request.remote_processor_url.as_deref() else {
                    return Err(CliErrorKind::workflow_parse(
                        "remote voice processing requires remote_processor_url",
                    )
                    .into());
                };
                if !url.starts_with("https://") {
                    return Err(CliErrorKind::workflow_parse(
                        "remote voice processing requires an https URL",
                    )
                    .into());
                }
                if !accepted.contains(sink) {
                    accepted.push(*sink);
                }
            }
        }
    }
    Ok(accepted)
}

async fn forward_chunk_to_remote(
    record: &VoiceSessionRecord,
    request: &VoiceAudioChunkRequest,
) -> Result<(), CliError> {
    let Some(url) = record.remote_processor_url.as_deref() else {
        return Ok(());
    };
    let response = reqwest::Client::new()
        .post(url)
        .json(request)
        .send()
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("send voice chunk: {error}")))?;
    if !response.status().is_success() {
        return Err(CliErrorKind::workflow_io(format!(
            "remote voice processor returned {}",
            response.status()
        ))
        .into());
    }
    Ok(())
}

fn voice_root() -> PathBuf {
    state::daemon_root().join("voice")
}

fn session_dir(voice_session_id: &str) -> PathBuf {
    voice_root().join(voice_session_id)
}

fn session_record_path(voice_session_id: &str) -> PathBuf {
    session_dir(voice_session_id).join("session.json")
}

fn chunks_path(voice_session_id: &str) -> PathBuf {
    session_dir(voice_session_id).join("chunks.pcm")
}

fn chunks_metadata_path(voice_session_id: &str) -> PathBuf {
    session_dir(voice_session_id).join("chunks.jsonl")
}

fn transcript_path(voice_session_id: &str) -> PathBuf {
    session_dir(voice_session_id).join("transcript.jsonl")
}

fn read_record(voice_session_id: &str) -> Result<VoiceSessionRecord, CliError> {
    let path = session_record_path(voice_session_id);
    read_record_from_path(&path)?.ok_or_else(|| {
        CliErrorKind::workflow_io(format!("missing voice session {}", path.display())).into()
    })
}

fn read_record_from_path(path: &Path) -> Result<Option<VoiceSessionRecord>, CliError> {
    let data = match fs::read_to_string(path) {
        Ok(data) => data,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(CliErrorKind::workflow_io(format!(
                "read voice session {}: {error}",
                path.display()
            ))
            .into());
        }
    };
    serde_json::from_str(&data).map(Some).map_err(|error| {
        CliErrorKind::workflow_parse(format!("parse voice session {}: {error}", path.display()))
            .into()
    })
}

fn write_record(record: &VoiceSessionRecord) -> Result<(), CliError> {
    let path = session_record_path(&record.voice_session_id);
    let json = serde_json::to_string_pretty(record)
        .map_err(|error| CliErrorKind::workflow_parse(format!("encode voice session: {error}")))?;
    fs::write(&path, json).map_err(|error| {
        CliErrorKind::workflow_io(format!("write voice session {}: {error}", path.display()))
    })?;
    Ok(())
}

fn append_chunk_bytes(voice_session_id: &str, bytes: &[u8]) -> Result<(), CliError> {
    let path = chunks_path(voice_session_id);
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("open voice chunks {}: {error}", path.display()))
        })?;
    file.write_all(bytes).map_err(|error| {
        CliErrorKind::workflow_io(format!("write voice chunks {}: {error}", path.display()))
    })?;
    Ok(())
}

fn append_chunk_metadata(voice_session_id: &str, chunk: &StoredVoiceChunk) -> Result<(), CliError> {
    append_json_line(&chunks_metadata_path(voice_session_id), chunk)
}

fn append_json_line<T: Serialize>(path: &Path, value: &T) -> Result<(), CliError> {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("open voice log {}: {error}", path.display()))
        })?;
    serde_json::to_writer(&mut file, value)
        .map_err(|error| CliErrorKind::workflow_parse(format!("encode voice log: {error}")))?;
    file.write_all(b"\n").map_err(|error| {
        CliErrorKind::workflow_io(format!("write voice log {}: {error}", path.display()))
    })?;
    Ok(())
}

fn cleanup_session_after_error<T>(
    voice_session_id: &str,
    result: Result<T, CliError>,
) -> Result<T, CliError> {
    if result.is_err() {
        let _ = remove_session_dir(&session_dir(voice_session_id));
    }
    result
}

fn cleanup_abandoned_sessions_at(now: &DateTime<Utc>) -> Result<(), CliError> {
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

fn remove_session_dir(path: &Path) -> Result<(), CliError> {
    if path.exists() {
        fs::remove_dir_all(path).map_err(|error| {
            CliErrorKind::workflow_io(format!("remove voice session {}: {error}", path.display()))
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
