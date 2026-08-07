use super::*;

#[test]
fn prepared_rejection_settles_instead_of_becoming_pending_again() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();
    let acknowledgment = SignalAck {
        result: AckResult::Rejected,
        details: Some("cancelled".into()),
        ..accepted_ack(&signal.signal_id)
    };
    write_prepared_ack(&signal_dir, &acknowledgment);

    let SignalFileState::Acknowledged(stored) = ensure_signal_file(&signal_dir, &signal).unwrap()
    else {
        panic!("prepared rejection must settle without reviving delivery")
    };

    assert!(acknowledgments_match(&stored, &acknowledgment));
    assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
    assert_eq!(read_acknowledgments(&signal_dir).unwrap().len(), 1);
}

#[test]
fn prepared_acceptance_survives_expiry_settlement() {
    let (_tmp, signal_dir, prepared) = prepared_acceptance();
    let expired = SignalAck {
        acknowledged_at: "2026-03-28T12:05:00Z".into(),
        result: AckResult::Expired,
        details: Some("expired".into()),
        ..prepared.clone()
    };

    let SignalSettlement::Acknowledged(stored) =
        settle_signal_if_present(&signal_dir, &expired).unwrap()
    else {
        panic!("prepared acceptance must remain known during expiry settlement")
    };

    assert!(acknowledgments_match(&stored, &prepared));
    assert_settled_acceptance(&signal_dir);
}

#[test]
fn prepared_acceptance_survives_cancellation_settlement() {
    let (_tmp, signal_dir, prepared) = prepared_acceptance();
    let rejected = SignalAck {
        acknowledged_at: "2026-03-28T12:05:00Z".into(),
        result: AckResult::Rejected,
        details: Some("cancelled".into()),
        ..prepared
    };

    acknowledge_signal_once(&signal_dir, &rejected)
        .expect_err("cancellation must not replace a delivered acceptance");

    assert_settled_acceptance(&signal_dir);
}

fn prepared_acceptance() -> (tempfile::TempDir, PathBuf, SignalAck) {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();
    let prepared = accepted_ack(&signal.signal_id);
    write_prepared_ack(&signal_dir, &prepared);
    (tmp, signal_dir, prepared)
}

fn assert_settled_acceptance(signal_dir: &Path) {
    assert!(read_pending_signals(signal_dir).unwrap().is_empty());
    let acknowledgments = read_acknowledgments(signal_dir).unwrap();
    assert_eq!(acknowledgments.len(), 1);
    assert_eq!(acknowledgments[0].result, AckResult::Accepted);
}
