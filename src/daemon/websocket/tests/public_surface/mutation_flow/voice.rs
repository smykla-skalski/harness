use super::*;

#[test]
fn websocket_voice_mutations_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "HARNESS_DAEMON_DATA_HOME",
            Some(sandbox.path().to_string_lossy().as_ref()),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let state = test_http_state_with_db();
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));

                    let start_request = WsRequest {
                        id: "req-voice-start".into(),
                        method: ws_methods::VOICE_START_SESSION.into(),
                        params: serde_json::json!({
                            "session_id": "voice-session-parent",
                            "actor": "harness-app",
                            "locale_identifier": "en_US",
                            "requested_sinks": ["localDaemon"],
                            "route_target": {
                                "kind": "codexPrompt",
                                "run_id": null,
                                "agent_id": null,
                                "command": null,
                                "action_hint": null
                            },
                            "requires_confirmation": true,
                            "remote_processor_url": null
                        }),
                        trace_context: None,
                    };

                    let started = dispatch(&start_request, &state, &connection).await;
                    assert!(started.error.is_none());
                    let voice_session_id = started
                        .result
                        .as_ref()
                        .and_then(|result| result["voice_session_id"].as_str())
                        .expect("voice session id")
                        .to_string();

                    let append_audio = WsRequest {
                        id: "req-voice-audio".into(),
                        method: ws_methods::VOICE_APPEND_AUDIO.into(),
                        params: serde_json::json!({
                            "voice_session_id": voice_session_id,
                            "actor": "harness-app",
                            "sequence": 1,
                            "format": {
                                "sample_rate": 48_000.0,
                                "channel_count": 1,
                                "common_format": "pcm_f32",
                                "interleaved": false
                            },
                            "frame_count": 4,
                            "started_at_seconds": 0.0,
                            "duration_seconds": 0.01,
                            "audio_base64": "AQIDBA=="
                        }),
                        trace_context: None,
                    };
                    let audio_response = dispatch(&append_audio, &state, &connection).await;
                    assert!(audio_response.error.is_none());

                    let append_transcript = WsRequest {
                        id: "req-voice-transcript".into(),
                        method: ws_methods::VOICE_APPEND_TRANSCRIPT.into(),
                        params: serde_json::json!({
                            "voice_session_id": append_audio
                                .params["voice_session_id"]
                                .as_str()
                                .expect("voice session id"),
                            "actor": "harness-app",
                            "segment": {
                                "sequence": 1,
                                "text": "patch the failing test",
                                "is_final": true,
                                "started_at_seconds": 0.0,
                                "duration_seconds": 0.5,
                                "confidence": null
                            }
                        }),
                        trace_context: None,
                    };
                    let transcript_response =
                        dispatch(&append_transcript, &state, &connection).await;
                    assert!(transcript_response.error.is_none());

                    let finish_request = WsRequest {
                        id: "req-voice-finish".into(),
                        method: ws_methods::VOICE_FINISH_SESSION.into(),
                        params: serde_json::json!({
                            "voice_session_id": append_transcript
                                .params["voice_session_id"]
                                .as_str()
                                .expect("voice session id"),
                            "actor": "harness-app",
                            "reason": "completed",
                            "confirmed_text": "patch the failing test"
                        }),
                        trace_context: None,
                    };
                    let finished = dispatch(&finish_request, &state, &connection).await;
                    assert!(finished.error.is_none());
                    assert_eq!(
                        finished
                            .result
                            .as_ref()
                            .and_then(|result| result["status"].as_str()),
                        Some("completed")
                    );
                });
            },
        );
    });
}
