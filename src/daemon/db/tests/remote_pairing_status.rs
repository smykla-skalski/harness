use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingCode, RemotePairingRecord, RemotePairingStatus,
};

#[test]
fn remote_pairing_status_classifies_lifecycle_without_exposing_records() {
    let db = DaemonDb::open_in_memory().expect("open db");
    seed_pairing(
        &db,
        "pairing-status-pending",
        "pending-status-secret",
        "2099-07-13T12:10:00Z",
    );
    let claimed = seed_pairing(
        &db,
        "pairing-status-claimed",
        "claimed-status-secret",
        "2099-07-13T12:10:00Z",
    );
    seed_pairing(
        &db,
        "pairing-status-expired",
        "expired-status-secret",
        "2026-07-13T12:01:00Z",
    );
    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-status-claimed",
        "Status Client",
        "macos",
        Some("203.0.113.80"),
        "audit-status-claim",
    )
    .expect("claim request");
    db.claim_remote_pairing_code(claimed.expose(), &claim, "2026-07-13T12:00:30Z")
        .expect("claim pairing");

    let now = "2026-07-13T12:02:00Z";
    assert_eq!(
        db.load_remote_pairing_status("pairing-status-pending", now)
            .expect("pending status"),
        RemotePairingStatus::Pending
    );
    assert_eq!(
        db.load_remote_pairing_status("pairing-status-claimed", now)
            .expect("claimed status"),
        RemotePairingStatus::Claimed
    );
    assert_eq!(
        db.load_remote_pairing_status("pairing-status-expired", now)
            .expect("expired status"),
        RemotePairingStatus::Expired
    );
    assert_eq!(
        db.load_remote_pairing_status("pairing-status-expired", now)
            .expect("repeated expired status"),
        RemotePairingStatus::Expired
    );
    let expiration_events = db
        .load_remote_audit_events(20)
        .expect("pairing expiration audits")
        .into_iter()
        .filter(|event| event.route_or_method == "remote.pair.expire")
        .collect::<Vec<_>>();
    assert_eq!(expiration_events.len(), 1);
    assert_eq!(
        expiration_events[0].event_id,
        "remote-pair-expire-pairing-status-expired"
    );
    assert_eq!(expiration_events[0].recorded_at, "2026-07-13T12:01:00Z");
    assert_eq!(
        db.load_remote_pairing_status("unknown-pairing-id", now)
            .expect("unknown status"),
        RemotePairingStatus::Unavailable
    );
    assert_eq!(
        db.load_remote_pairing_status("   ", now)
            .expect("blank status"),
        RemotePairingStatus::Unavailable
    );
}

fn seed_pairing(
    db: &DaemonDb,
    pairing_id: &str,
    code: &str,
    expires_at: &str,
) -> RemotePairingCode {
    let code = RemotePairingCode::from_value_for_tests(code);
    let record = RemotePairingRecord::new_for_tests(
        pairing_id,
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-07-13T12:00:00Z",
        expires_at,
    )
    .expect("pairing record");
    db.create_remote_pairing_code(&record, &format!("audit-create-{pairing_id}"))
        .expect("create pairing");
    code
}
