use serde_json::json;

use super::*;

fn sample_signal() -> Signal {
    Signal {
        signal_id: "sig-test-001".into(),
        version: 1,
        created_at: "2026-03-28T12:00:00Z".into(),
        expires_at: "2026-03-28T12:05:00Z".into(),
        source_agent: "claude".into(),
        command: "inject_context".into(),
        priority: SignalPriority::Normal,
        payload: SignalPayload {
            message: "test signal".into(),
            action_hint: None,
            related_files: vec![],
            metadata: json!(null),
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: None,
        },
    }
}

#[test]
fn signal_write_and_read_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();
    let signals = read_pending_signals(&signal_dir).unwrap();
    assert_eq!(signals.len(), 1);
    assert_eq!(signals[0].signal_id, "sig-test-001");
}

#[test]
fn acknowledge_moves_signal() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();

    let ack = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "sess-1".into(),
        details: None,
    };
    acknowledge_signal(&signal_dir, &ack).unwrap();

    let pending = read_pending_signals(&signal_dir).unwrap();
    assert!(pending.is_empty());

    let acks = read_acknowledgments(&signal_dir).unwrap();
    assert_eq!(acks.len(), 1);
    assert_eq!(acks[0].result, AckResult::Accepted);
}

#[test]
fn read_acknowledgments_ignores_acknowledged_signal_payloads() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();

    let ack = SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "sess-1".into(),
        details: None,
    };
    acknowledge_signal(&signal_dir, &ack).unwrap();

    let acknowledgments = read_acknowledgments(&signal_dir).unwrap();
    let acknowledged_signals = read_acknowledged_signals(&signal_dir).unwrap();
    let payload_path = acknowledged_dir(&signal_dir).join("sig-test-001.json");

    assert_eq!(acknowledgments.len(), 1);
    assert_eq!(acknowledged_signals.len(), 1);
    assert!(payload_path.exists());
}

#[test]
fn read_empty_dir_returns_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let signals = read_pending_signals(tmp.path()).unwrap();
    assert!(signals.is_empty());
    let acks = read_acknowledgments(tmp.path()).unwrap();
    assert!(acks.is_empty());
}

#[test]
fn check_signal_timeouts_detects_expired() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");

    let mut signal = sample_signal();
    signal.created_at = "2020-01-01T00:00:00Z".into();
    signal.expires_at = "2020-01-01T00:05:00Z".into();
    write_signal_file(&signal_dir, &signal).unwrap();

    let timed_out = check_signal_timeouts(&signal_dir, 60).unwrap();
    assert_eq!(timed_out.len(), 1);
    assert_eq!(timed_out[0].signal_id, "sig-test-001");
}

#[test]
fn check_signal_timeouts_ignores_fresh_signals() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let mut signal = sample_signal();
    signal.created_at = chrono::Utc::now().to_rfc3339();
    write_signal_file(&signal_dir, &signal).unwrap();

    let timed_out = check_signal_timeouts(&signal_dir, 600).unwrap();
    assert!(timed_out.is_empty());
}

#[test]
fn cleanup_pending_signals_moves_to_acknowledged() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    write_signal_file(&signal_dir, &sample_signal()).unwrap();

    cleanup_pending_signals(&signal_dir, "dead-agent", "sess-1").unwrap();

    assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
    let acks = read_acknowledgments(&signal_dir).unwrap();
    assert_eq!(acks.len(), 1);
    assert_eq!(acks[0].result, AckResult::Expired);
}

#[test]
fn malformed_pending_signal_is_quarantined() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let pending = pending_dir(&signal_dir);
    fs::create_dir_all(&pending).unwrap();
    let malformed = pending.join("sig-bad.json");
    fs::write(&malformed, "{ not valid json").unwrap();

    let signals = read_pending_signals(&signal_dir).unwrap();

    assert!(signals.is_empty());
    assert!(
        !malformed.exists(),
        "malformed file should be moved out of pending"
    );
    let quarantined: Vec<_> = fs::read_dir(&pending)
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("sig-bad.json.corrupt"))
        })
        .collect();
    assert_eq!(quarantined.len(), 1);
}

#[test]
fn acknowledge_signal_surfaces_rename_failures() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    fs::create_dir_all(pending_dir(&signal_dir)).unwrap();

    let ack = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "sess-1".into(),
        details: None,
    };

    let error = acknowledge_signal(&signal_dir, &ack).unwrap_err();
    assert!(
        error.to_string().contains("move acknowledged signal"),
        "rename failure should be surfaced: {error}"
    );
}

#[test]
fn write_signal_file_rejects_unsafe_signal_id() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let escaped = tmp.path().join("escape.json");
    let mut signal = sample_signal();
    signal.signal_id = "../../escape".into();

    let error = write_signal_file(&signal_dir, &signal).unwrap_err();

    assert!(
        error.to_string().contains("unsafe name") || error.to_string().contains("unsafe"),
        "{error}"
    );
    assert!(!escaped.exists());
}

#[test]
fn acknowledge_signal_rejects_unsafe_signal_id() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let escaped_ack = tmp.path().join("escape.ack.json");

    let ack = SignalAck {
        signal_id: "../../escape".into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "sess-1".into(),
        details: None,
    };

    let error = acknowledge_signal(&signal_dir, &ack).unwrap_err();

    assert!(
        error.to_string().contains("unsafe name") || error.to_string().contains("unsafe"),
        "{error}"
    );
    assert!(!escaped_ack.exists());
}
