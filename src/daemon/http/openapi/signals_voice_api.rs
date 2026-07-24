//! Session signals and voice [`utoipa::OpenApi`] aggregator. Kept in its own
//! module so the path list does not push `openapi/mod.rs` past the file-length
//! cap.

#[derive(utoipa::OpenApi)]
#[openapi(paths(
    super::super::signals::post_send_signal,
    super::super::signals::post_cancel_signal,
    super::super::signals::post_signal_ack,
    super::super::voice::post_voice_session,
    super::super::voice::post_voice_audio_chunk,
    super::super::voice::post_voice_transcript,
    super::super::voice::post_voice_finish,
))]
pub(super) struct SignalsVoiceApi;
