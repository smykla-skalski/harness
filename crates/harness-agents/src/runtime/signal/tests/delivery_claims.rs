use super::*;

#[test]
fn accepted_claim_remains_pending_until_delivery_commit() {
    let tmp = tempfile::tempdir().unwrap();
    let signal_dir = tmp.path().join("signals");
    let signal = sample_signal();
    write_signal_file(&signal_dir, &signal).unwrap();
    let acknowledgment = accepted_ack(&signal.signal_id);

    let claim = claim_signal_acknowledgment(&signal_dir, &acknowledgment).unwrap();

    let SignalAckClaim::Created(delivery) = claim else {
        panic!("first caller must own delivery")
    };
    assert_eq!(read_pending_signals(&signal_dir).unwrap().len(), 1);
    assert!(read_acknowledgments(&signal_dir).unwrap().is_empty());

    delivery.commit().unwrap();

    assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
    assert_eq!(read_acknowledgments(&signal_dir).unwrap().len(), 1);
}
