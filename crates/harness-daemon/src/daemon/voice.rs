//! Voice-session recording and persistence moved into `harness_voice`; this
//! module is the thin adapter that keeps the daemon's own call sites
//! (`http`, `websocket`, `service`) unchanged.
//!
//! Its wire types already live in `harness_protocol::daemon::voice`, so
//! `harness_voice` depends on that crate directly and every function here is
//! a plain passthrough. The one thing that keeps this from being a bare
//! `pub use harness_voice::*;` re-export like `crate::timeline` is the
//! storage root: `harness_voice` takes it as a plain `&Path` parameter
//! rather than resolving its own `daemon::state::daemon_root()`, which goes
//! through the daemon's process ownership model (managed vs. standalone,
//! macOS app group) that a leaf storage crate has no business knowing
//! about. This module resolves the root and passes it in on every call.

use harness_kernel::errors::CliError;
use harness_protocol::daemon::voice::{
    VoiceAudioChunkRequest, VoiceSessionFinishRequest, VoiceSessionMutationResponse,
    VoiceSessionStartRequest, VoiceSessionStartResponse, VoiceTranscriptUpdateRequest,
};

use super::state;

fn voice_storage_root() -> std::path::PathBuf {
    state::daemon_root()
}

/// Start a session-scoped voice-processing record.
///
/// # Errors
/// Returns `CliError` when the sink request is invalid or the metadata cannot be persisted.
pub fn start_session(
    harness_session_id: &str,
    request: &VoiceSessionStartRequest,
) -> Result<VoiceSessionStartResponse, CliError> {
    harness_voice::start_session(&voice_storage_root(), harness_session_id, request)
}

/// Start a session-scoped voice-processing record on a blocking worker.
///
/// # Errors
/// Returns `CliError` when the sink request is invalid or the metadata cannot be persisted.
pub async fn start_session_async(
    harness_session_id: &str,
    request: &VoiceSessionStartRequest,
) -> Result<VoiceSessionStartResponse, CliError> {
    harness_voice::start_session_async(&voice_storage_root(), harness_session_id, request).await
}

/// Persist and optionally forward a live audio chunk.
///
/// # Errors
/// Returns `CliError` for invalid ordering, oversized payloads, decode failures, or sink failures.
pub async fn append_audio_chunk(
    voice_session_id: &str,
    request: &VoiceAudioChunkRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    harness_voice::append_audio_chunk(&voice_storage_root(), voice_session_id, request).await
}

/// Persist a live transcript update for the voice session.
///
/// # Errors
/// Returns `CliError` when the transcript file cannot be updated.
pub fn append_transcript(
    voice_session_id: &str,
    request: &VoiceTranscriptUpdateRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    harness_voice::append_transcript(&voice_storage_root(), voice_session_id, request)
}

/// Persist a live transcript update for the voice session on a blocking worker.
///
/// # Errors
/// Returns `CliError` when the transcript file cannot be updated.
pub async fn append_transcript_async(
    voice_session_id: &str,
    request: &VoiceTranscriptUpdateRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    harness_voice::append_transcript_async(&voice_storage_root(), voice_session_id, request).await
}

/// Finish or cancel a voice session and clean up transient audio data.
///
/// # Errors
/// Returns `CliError` when cleanup fails.
pub fn finish_session(
    voice_session_id: &str,
    request: &VoiceSessionFinishRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    harness_voice::finish_session(&voice_storage_root(), voice_session_id, request)
}

/// Finish or cancel a voice session and clean up transient audio data on a blocking worker.
///
/// # Errors
/// Returns `CliError` when cleanup fails.
pub async fn finish_session_async(
    voice_session_id: &str,
    request: &VoiceSessionFinishRequest,
) -> Result<VoiceSessionMutationResponse, CliError> {
    harness_voice::finish_session_async(&voice_storage_root(), voice_session_id, request).await
}

/// Remove abandoned voice-session artifacts from prior crashed or disconnected flows.
///
/// # Errors
/// Returns `CliError` when cleanup cannot enumerate or delete session directories.
pub fn cleanup_abandoned_sessions() -> Result<(), CliError> {
    harness_voice::cleanup_abandoned_sessions(&voice_storage_root())
}

#[cfg(test)]
mod tests;
