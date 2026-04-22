use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{
    VoiceAudioChunkRequest, VoiceSessionFinishRequest, VoiceSessionStartRequest,
    VoiceTranscriptUpdateRequest, http_paths,
};
use crate::daemon::voice::{append_audio_chunk, append_transcript, finish_session, start_session};

use super::DaemonHttpState;
use super::auth::authorize_control_request;
use super::response::{extract_request_id, timed_json};

pub(super) fn voice_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::SESSION_VOICE_START, post(post_voice_session))
        .route(http_paths::VOICE_AUDIO_APPEND, post(post_voice_audio_chunk))
        .route(
            http_paths::VOICE_TRANSCRIPT_APPEND,
            post(post_voice_transcript),
        )
        .route(http_paths::VOICE_FINISH, post(post_voice_finish))
}

async fn post_voice_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceSessionStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        http_paths::SESSION_VOICE_START,
        &request_id,
        start,
        start_session(&session_id, &request),
    )
}

async fn post_voice_audio_chunk(
    Path(voice_session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceAudioChunkRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        http_paths::VOICE_AUDIO_APPEND,
        &request_id,
        start,
        append_audio_chunk(&voice_session_id, &request).await,
    )
}

async fn post_voice_transcript(
    Path(voice_session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceTranscriptUpdateRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        http_paths::VOICE_TRANSCRIPT_APPEND,
        &request_id,
        start,
        append_transcript(&voice_session_id, &request),
    )
}

async fn post_voice_finish(
    Path(voice_session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceSessionFinishRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        http_paths::VOICE_FINISH,
        &request_id,
        start,
        finish_session(&voice_session_id, &request),
    )
}
