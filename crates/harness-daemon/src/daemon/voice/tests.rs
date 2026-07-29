use tempfile::tempdir;

use super::*;
use harness_protocol::daemon::voice::{
    VoiceAudioFormatDescriptor, VoiceProcessingSink, VoiceRouteTarget, VoiceRouteTargetKind,
    VoiceSessionFinishReason,
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

fn with_temp_voice_root<F: FnOnce()>(f: F) {
    let tempdir = tempdir().expect("tempdir");
    let data_home = tempdir.path().to_string_lossy().into_owned();
    temp_env::with_var("HARNESS_DAEMON_DATA_HOME", Some(data_home.as_str()), f);
}

/// Regression coverage for this module's own job: resolving the real
/// `daemon::state::daemon_root()` as the storage root and delegating to
/// `harness_voice` unchanged. `harness-voice`'s own test suite covers the
/// recording/persistence behavior itself against a directly-supplied temp
/// directory.
#[test]
fn adapter_resolves_daemon_root_and_delegates_to_harness_voice() {
    with_temp_voice_root(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let started = start_session_async("session-a", &request())
                .await
                .expect("start");
            assert_eq!(
                started.accepted_sinks,
                vec![VoiceProcessingSink::LocalDaemon]
            );
            assert_eq!(started.status, "recording");

            let mutation = append_audio_chunk(
                &started.voice_session_id,
                &VoiceAudioChunkRequest {
                    actor: "harness-app".into(),
                    sequence: 1,
                    format: VoiceAudioFormatDescriptor {
                        sample_rate: 48_000.0,
                        channel_count: 1,
                        common_format: "pcm_f32".into(),
                        interleaved: false,
                    },
                    frame_count: 4,
                    started_at_seconds: 0.0,
                    duration_seconds: 0.01,
                    audio_base64: "AQIDBA==".into(),
                },
            )
            .await
            .expect("chunk");
            assert_eq!(mutation.voice_session_id, started.voice_session_id);

            let finished = finish_session_async(
                &started.voice_session_id,
                &VoiceSessionFinishRequest {
                    actor: "harness-app".into(),
                    reason: VoiceSessionFinishReason::Completed,
                    confirmed_text: None,
                },
            )
            .await
            .expect("finish");
            assert_eq!(finished.status, "completed");
        });
    });
}

#[test]
fn adapter_surfaces_remote_sink_validation_errors() {
    with_temp_voice_root(|| {
        let mut body = request();
        body.requested_sinks = vec![VoiceProcessingSink::RemoteProcessor];
        body.remote_processor_url = Some("http://example.test/audio".into());

        let error = start_session("session-b", &body).expect_err("http sink rejected");
        assert!(
            error
                .to_string()
                .contains("remote voice processing requires an https URL")
        );
    });
}
