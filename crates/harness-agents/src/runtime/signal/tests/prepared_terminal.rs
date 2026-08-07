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
