use harness::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
};

#[test]
fn signal_write_acknowledge_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("signal-test")),
        ],
        || {
            let signal_dir = tmp.path().join("signals/test-agent/sess-1");

            let signal = Signal {
                signal_id: "sig-integ-001".into(),
                version: 1,
                created_at: "2026-03-28T12:00:00Z".into(),
                expires_at: "2026-03-28T12:05:00Z".into(),
                source_agent: "observer".into(),
                command: "inject_context".into(),
                priority: SignalPriority::Normal,
                payload: SignalPayload {
                    message: "test message".into(),
                    action_hint: None,
                    related_files: vec![],
                    metadata: serde_json::Value::Null,
                },
                delivery: DeliveryConfig {
                    max_retries: 1,
                    retry_count: 0,
                    idempotency_key: None,
                },
            };

            let path =
                harness::agents::runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();
            assert!(path.exists());

            let pending =
                harness::agents::runtime::signal::read_pending_signals(&signal_dir).unwrap();
            assert_eq!(pending.len(), 1);
            assert_eq!(pending[0].signal_id, "sig-integ-001");

            let ack = SignalAck {
                signal_id: "sig-integ-001".into(),
                acknowledged_at: "2026-03-28T12:00:03Z".into(),
                result: AckResult::Accepted,
                agent: "claude".into(),
                session_id: "sess-1".into(),
                details: None,
            };
            harness::agents::runtime::signal::acknowledge_signal(&signal_dir, &ack).unwrap();

            let pending =
                harness::agents::runtime::signal::read_pending_signals(&signal_dir).unwrap();
            assert!(pending.is_empty());

            let acks = harness::agents::runtime::signal::read_acknowledgments(&signal_dir).unwrap();
            assert_eq!(acks.len(), 1);
            assert_eq!(acks[0].result, AckResult::Accepted);
        },
    );
}

#[test]
fn signal_serde_round_trip() {
    let signal = Signal {
        signal_id: "sig-serde-001".into(),
        version: 1,
        created_at: "2026-03-28T12:00:00Z".into(),
        expires_at: "2026-03-28T12:05:00Z".into(),
        source_agent: "claude".into(),
        command: "request_action".into(),
        priority: SignalPriority::High,
        payload: SignalPayload {
            message: "please fix this".into(),
            action_hint: Some("review_and_fix".into()),
            related_files: vec!["src/main.rs".into()],
            metadata: serde_json::json!({"key": "value"}),
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 1,
            idempotency_key: Some("fix-001".into()),
        },
    };
    let json = serde_json::to_string_pretty(&signal).unwrap();
    let parsed: Signal = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed.signal_id, "sig-serde-001");
    assert_eq!(parsed.priority, SignalPriority::High);
    assert_eq!(parsed.delivery.retry_count, 1);
    assert_eq!(parsed.payload.related_files.len(), 1);
}
