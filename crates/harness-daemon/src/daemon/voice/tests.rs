use serde_json::json;

use super::*;
use crate::daemon::protocol::{
    VoiceAudioFormatDescriptor, VoiceRouteTarget, VoiceRouteTargetKind, VoiceTranscriptSegment,
};

fn request() -> VoiceSessionStartRequest {
    VoiceSessionStartRequest {
        actor: "harness-app".into(),
        locale_identifier: "en_US".into(),
        requested_sinks: vec![VoiceProcessingSink::LocalDaemon],
        route_target: VoiceRouteTarget {
            kind: VoiceRouteTargetKind::CodexPrompt,
            run_id: None,
            agent_id: None,
            command: None,
            action_hint: None,
        },
        requires_confirmation: true,
        remote_processor_url: None,
    }
}

fn chunk(sequence: u64) -> VoiceAudioChunkRequest {
    VoiceAudioChunkRequest {
        actor: "harness-app".into(),
        sequence,
        format: VoiceAudioFormatDescriptor {
            sample_rate: 48_000.0,
            channel_count: 1,
            common_format: "pcm_f32".into(),
            interleaved: false,
        },
        frame_count: 4,
        started_at_seconds: 0.0,
        duration_seconds: 0.01,
        audio_base64: STANDARD.encode([1_u8, 2, 3, 4]),
    }
}

fn with_temp_voice_root<F: FnOnce()>(f: F) {
    let tempdir = tempfile::tempdir().expect("tempdir");
    let data_home = tempdir.path().to_string_lossy().into_owned();
    temp_env::with_var("HARNESS_DAEMON_DATA_HOME", Some(data_home.as_str()), f);
}

fn write_stale_session(voice_session_id: &str) {
    fs::create_dir_all(session_dir(voice_session_id)).expect("create voice session dir");
    fs::write(
        session_record_path(voice_session_id),
        serde_json::to_string_pretty(&json!({
            "voice_session_id": voice_session_id,
            "harness_session_id": "session-a",
            "actor": "harness-app",
            "locale_identifier": "en_US",
            "accepted_sinks": ["localDaemon"],
            "route_target": {
                "kind": "codexPrompt",
                "run_id": null,
                "agent_id": null,
                "command": null,
                "action_hint": null
            },
            "requires_confirmation": true,
            "remote_processor_url": null,
            "created_at": "2000-01-01T00:00:00Z",
            "last_sequence": 1
        }))
        .expect("serialize stale session"),
    )
    .expect("write stale session");
    fs::write(chunks_path(voice_session_id), [1_u8, 2, 3, 4]).expect("write chunks");
    fs::write(chunks_metadata_path(voice_session_id), "{}\n").expect("write chunk metadata");
    fs::write(transcript_path(voice_session_id), "{}\n").expect("write transcript");
}

#[test]
fn start_session_cleans_up_stale_voice_sessions() {
    with_temp_voice_root(|| {
        let stale_session_id = "voice-stale";
        write_stale_session(stale_session_id);

        start_session("session-b", &request()).expect("start");

        assert!(
            !session_dir(stale_session_id).exists(),
            "stale voice data survived startup cleanup"
        );
    });
}

#[test]
fn append_audio_chunk_error_cleans_up_voice_session() {
    with_temp_voice_root(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let started = start_session("session-a", &request()).expect("start");
            let dir = session_dir(&started.voice_session_id);

            let error = append_audio_chunk(&started.voice_session_id, &chunk(2))
                .await
                .expect_err("out-of-order chunk rejected");

            assert!(
                error
                    .to_string()
                    .contains("voice chunk sequence out of order")
            );
            assert!(!dir.exists(), "error path left voice session on disk");
        });
    });
}

#[test]
fn voice_session_persists_chunk_sequence_and_cleans_up() {
    with_temp_voice_root(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let started = start_session("session-a", &request()).expect("start");
            append_audio_chunk(&started.voice_session_id, &chunk(1))
                .await
                .expect("chunk");
            append_transcript(
                &started.voice_session_id,
                &VoiceTranscriptUpdateRequest {
                    actor: "harness-app".into(),
                    segment: VoiceTranscriptSegment {
                        sequence: 1,
                        text: "patch the failing test".into(),
                        is_final: true,
                        started_at_seconds: 0.0,
                        duration_seconds: 0.5,
                        confidence: None,
                    },
                },
            )
            .expect("transcript");
            let dir = session_dir(&started.voice_session_id);
            assert!(dir.join("chunks.pcm").is_file());
            finish_session(
                &started.voice_session_id,
                &VoiceSessionFinishRequest {
                    actor: "harness-app".into(),
                    reason: VoiceSessionFinishReason::Completed,
                    confirmed_text: Some("patch the failing test".into()),
                },
            )
            .expect("finish");
            assert!(!dir.exists());
        });
    });
}

#[test]
fn remote_voice_sink_requires_https_url() {
    let mut request = request();
    request.requested_sinks = vec![VoiceProcessingSink::RemoteProcessor];
    request.remote_processor_url = Some("http://example.test/audio".into());

    let error = accepted_sinks(&request).expect_err("http sink rejected");
    assert!(
        error
            .to_string()
            .contains("remote voice processing requires an https URL")
    );
}
