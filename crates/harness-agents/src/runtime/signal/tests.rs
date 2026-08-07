use serde_json::json;

use super::*;

mod delivery_claims;
mod prepared_terminal;

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

fn accepted_ack(signal_id: &str) -> SignalAck {
    SignalAck {
        signal_id: signal_id.into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: None,
    }
}

fn write_prepared_ack(signal_dir: &Path, acknowledgment: &SignalAck) {
    let acknowledged = acknowledged_dir(signal_dir);
    fs::create_dir_all(&acknowledged).unwrap();
    fs::write(
        acknowledged.join(format!("{}.ack.json", acknowledgment.signal_id)),
        serde_json::to_string_pretty(acknowledgment).unwrap(),
    )
    .unwrap();
}

fn assert_settled_delivery(signal_dir: &Path, signal: &Signal, expected: &SignalAck) {
    assert!(read_pending_signals(signal_dir).unwrap().is_empty());
    assert!(
        acknowledged_dir(signal_dir)
            .join(format!("{}.json", signal.signal_id))
            .exists()
    );
    assert_eq!(read_acknowledgments(signal_dir).unwrap().len(), 1);
    let SignalFileState::Acknowledged(stored) = ensure_signal_file(signal_dir, signal).unwrap()
    else {
        panic!("settled acknowledgment must prevent payload recreation")
    };
    assert!(acknowledgments_match(&stored, expected));
    assert_eq!(stored.acknowledged_at, expected.acknowledged_at);
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
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
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
fn acknowledge_signal_preserves_the_first_acknowledgment() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    write_signal_file(&signal_dir, &sample_signal()).unwrap();
    let accepted = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: None,
    };
    acknowledge_signal(&signal_dir, &accepted).unwrap();
    acknowledge_signal(&signal_dir, &accepted).expect("identical retry must be idempotent");
    let rejected = SignalAck {
        result: AckResult::Rejected,
        details: Some("cancelled".into()),
        ..accepted
    };

    acknowledge_signal(&signal_dir, &rejected)
        .expect_err("a later acknowledgment must not overwrite the first");

    let acknowledgments = read_acknowledgments(&signal_dir).unwrap();
    assert_eq!(acknowledgments.len(), 1);
    assert_eq!(acknowledgments[0].result, AckResult::Accepted);
}

#[test]
fn concurrent_acknowledgments_preserve_the_first_writer() {
    use std::sync::{Arc, Barrier};
    use std::thread;

    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    write_signal_file(&signal_dir, &sample_signal()).unwrap();
    let accepted = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: None,
    };
    let rejected = SignalAck {
        result: AckResult::Rejected,
        details: Some("cancelled".into()),
        ..accepted.clone()
    };
    let barrier = Arc::new(Barrier::new(2));
    let attempts = [accepted, rejected].map(|acknowledgment| {
        let signal_dir = signal_dir.clone();
        let barrier = Arc::clone(&barrier);
        thread::spawn(move || {
            barrier.wait();
            let result = acknowledge_signal(&signal_dir, &acknowledgment);
            (acknowledgment.result, result)
        })
    });
    let results = attempts.map(|attempt| attempt.join().unwrap());

    assert_eq!(
        results.iter().filter(|(_, result)| result.is_ok()).count(),
        1
    );
    let winner = results
        .iter()
        .find_map(|(result, outcome)| outcome.is_ok().then_some(*result))
        .expect("one acknowledgment wins");
    let acknowledgments = read_acknowledgments(&signal_dir).unwrap();
    assert_eq!(acknowledgments.len(), 1);
    assert_eq!(acknowledgments[0].result, winner);
}

#[test]
fn concurrent_equivalent_acknowledgments_preserve_the_first_timestamp() {
    use std::sync::{Arc, Barrier};
    use std::thread;

    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    write_signal_file(&signal_dir, &sample_signal()).unwrap();
    let barrier = Arc::new(Barrier::new(2));
    let attempts = ["2026-03-28T12:00:03Z", "2026-03-28T12:00:04Z"].map(|timestamp| {
        let signal_dir = signal_dir.clone();
        let barrier = Arc::clone(&barrier);
        thread::spawn(move || {
            let acknowledgment = SignalAck {
                signal_id: "sig-test-001".into(),
                acknowledged_at: timestamp.into(),
                result: AckResult::Rejected,
                agent: "codex".into(),
                session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
                details: Some("cancelled".into()),
            };
            barrier.wait();
            acknowledge_signal_once(&signal_dir, &acknowledgment)
        })
    });

    let results = attempts.map(|attempt| attempt.join().unwrap().unwrap());
    assert_eq!(results[0].acknowledged_at, results[1].acknowledged_at);
    let acknowledgments = read_acknowledgments(&signal_dir).unwrap();
    assert_eq!(acknowledgments.len(), 1);
    assert_eq!(
        acknowledgments[0].acknowledged_at,
        results[0].acknowledged_at
    );
}

#[test]
fn ensure_signal_file_repairs_missing_delivery_without_reviving_acknowledged_signal() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();

    assert!(matches!(
        ensure_signal_file(&signal_dir, &signal).unwrap(),
        SignalFileState::Created
    ));
    assert!(matches!(
        ensure_signal_file(&signal_dir, &signal).unwrap(),
        SignalFileState::Pending
    ));
    let acknowledgment = SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: None,
    };
    acknowledge_signal(&signal_dir, &acknowledgment).unwrap();

    let SignalFileState::Acknowledged(stored) = ensure_signal_file(&signal_dir, &signal).unwrap()
    else {
        panic!("acknowledged signal must not be recreated")
    };
    assert_eq!(stored.acknowledged_at, acknowledgment.acknowledged_at);
    assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
}

#[test]
fn acknowledged_pending_signal_settles_without_redelivery() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();
    let acknowledgment = accepted_ack(&signal.signal_id);
    write_prepared_ack(&signal_dir, &acknowledgment);

    assert_eq!(read_pending_signals(&signal_dir).unwrap().len(), 1);
    let claim = claim_signal_acknowledgment(&signal_dir, &acknowledgment).unwrap();
    let SignalAckClaim::Existing(stored) = claim else {
        panic!("prepared acknowledgment must be terminal")
    };
    assert!(acknowledgments_match(&stored, &acknowledgment));
    assert_settled_delivery(&signal_dir, &signal, &acknowledgment);
}

#[test]
fn settle_signal_if_present_does_not_recreate_a_missing_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let acknowledgment = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:05:00Z".into(),
        result: AckResult::Expired,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: Some("expired".into()),
    };

    assert!(matches!(
        settle_signal_if_present(&signal_dir, &acknowledgment).unwrap(),
        SignalSettlement::Missing
    ));
    assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
    assert!(read_acknowledgments(&signal_dir).unwrap().is_empty());
}

#[test]
fn settle_signal_if_present_moves_an_existing_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    write_signal_file(&signal_dir, &sample_signal()).unwrap();
    let acknowledgment = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:05:00Z".into(),
        result: AckResult::Expired,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: Some("expired".into()),
    };

    let SignalSettlement::Acknowledged(stored) =
        settle_signal_if_present(&signal_dir, &acknowledgment).unwrap()
    else {
        panic!("existing payload must be settled")
    };
    assert_eq!(stored.result, AckResult::Expired);
    assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
    assert_eq!(read_acknowledgments(&signal_dir).unwrap().len(), 1);
}

#[test]
fn read_acknowledgments_ignores_acknowledged_signal_payloads() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();

    let ack = SignalAck {
        signal_id: signal.signal_id,
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
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

    cleanup_pending_signals(
        &signal_dir,
        "dead-agent",
        "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
    )
    .unwrap();

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
fn acknowledge_signal_rejects_a_missing_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    fs::create_dir_all(pending_dir(&signal_dir)).unwrap();

    let ack = SignalAck {
        signal_id: "sig-test-001".into(),
        acknowledged_at: "2026-03-28T12:00:03Z".into(),
        result: AckResult::Accepted,
        agent: "codex".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: None,
    };

    let error = acknowledge_signal(&signal_dir, &ack).unwrap_err();
    assert!(
        error.to_string().contains("pending signal") && error.to_string().contains("is missing"),
        "missing payload should be surfaced: {error}"
    );
    assert!(read_acknowledgments(&signal_dir).unwrap().is_empty());
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
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        details: None,
    };

    let error = acknowledge_signal(&signal_dir, &ack).unwrap_err();

    assert!(
        error.to_string().contains("unsafe name") || error.to_string().contains("unsafe"),
        "{error}"
    );
    assert!(!escaped_ack.exists());
}
