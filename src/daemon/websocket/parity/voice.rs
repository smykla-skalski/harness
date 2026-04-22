use super::{
    DaemonHttpState, VoiceAudioChunkRequest, VoiceSessionFinishRequest, VoiceSessionStartRequest,
    VoiceTranscriptUpdateRequest, WsRequest, WsResponse, append_audio_chunk, append_transcript,
    bind_control_plane_actor_value, dispatch_query_result, error_response, extract_session_id,
    extract_string_param, finish_session, start_session,
};

pub(crate) async fn dispatch_voice_start_session(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceSessionStartRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(&request.id, start_session(&session_id, &body))
}

pub(crate) async fn dispatch_voice_append_audio(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(voice_session_id) = extract_string_param(&request.params, "voice_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing voice_session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceAudioChunkRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(
        &request.id,
        append_audio_chunk(&voice_session_id, &body).await,
    )
}

pub(crate) async fn dispatch_voice_append_transcript(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(voice_session_id) = extract_string_param(&request.params, "voice_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing voice_session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceTranscriptUpdateRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(&request.id, append_transcript(&voice_session_id, &body))
}

pub(crate) async fn dispatch_voice_finish_session(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(voice_session_id) = extract_string_param(&request.params, "voice_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing voice_session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceSessionFinishRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(&request.id, finish_session(&voice_session_id, &body))
}
