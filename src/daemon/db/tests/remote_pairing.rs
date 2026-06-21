use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteAuditOutcome;
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingCode, RemotePairingRecord,
};

#[test]
fn remote_pairing_create_claim_rejects_replay_and_audits() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("pairing-secret-value");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-1",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");

    db.create_remote_pairing_code(&record, "audit-create-1")
        .expect("create pairing");
    let stored_hash: String = db
        .conn
        .query_row(
            "SELECT code_hash FROM remote_pairing_codes WHERE pairing_id = 'pairing-1'",
            [],
            |row| row.get(0),
        )
        .expect("stored pairing hash");
    assert!(!stored_hash.contains("pairing-secret-value"));

    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-1",
        "MacBook Pro",
        "macos",
        Some("203.0.113.10"),
        "audit-claim-1",
    )
    .expect("claim request");
    let claimed = db
        .claim_remote_pairing_code(code.expose(), &claim, "2026-06-21T13:41:00Z")
        .expect("claim pairing");

    assert_eq!(claimed.client.client_id, "client-1");
    assert_eq!(claimed.client.role, RemoteRole::Operator);
    assert!(!claimed.bearer_token.expose().is_empty());
    assert!(db
        .verify_remote_client_token("client-1", claimed.bearer_token.expose())
        .expect("verify paired client")
        .is_some());
    assert!(
        db.claim_remote_pairing_code(code.expose(), &claim, "2026-06-21T13:42:00Z")
            .is_err(),
        "pairing code must be single use"
    );

    let routes: Vec<_> = db
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert!(routes.contains(&"remote.pair.create".to_string()));
    assert!(routes.contains(&"remote.pair.claim".to_string()));
}

#[test]
fn remote_pairing_claim_rejects_expiry_and_wrong_domain_with_audit() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("expired-pairing-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-expired",
        RemoteRole::Viewer,
        &[],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:41:00Z",
    )
    .expect("pairing record");
    db.create_remote_pairing_code(&record, "audit-create-expired")
        .expect("create pairing");

    let expired_claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-expired",
        "iPhone",
        "ios",
        Some("203.0.113.20"),
        "audit-claim-expired",
    )
    .expect("expired claim");
    assert!(
        db.claim_remote_pairing_code(code.expose(), &expired_claim, "2026-06-21T13:42:00Z")
            .is_err(),
        "expired pairing code must be denied"
    );

    let wrong_domain_claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "evil.example.com",
        "client-wrong-domain",
        "iPhone",
        "ios",
        Some("203.0.113.21"),
        "audit-claim-wrong-domain",
    )
    .expect("wrong-domain claim");
    assert!(
        db.claim_remote_pairing_code(code.expose(), &wrong_domain_claim, "2026-06-21T13:40:30Z")
            .is_err(),
        "wrong-domain pairing claim must be denied"
    );

    let routes: Vec<_> = db
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert!(routes.contains(&"remote.pair.expire".to_string()));
    assert!(routes.contains(&"remote.pair.claim".to_string()));
}

#[test]
fn remote_pairing_claim_rejects_lost_claim_race() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("race-pairing-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-race",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");
    db.create_remote_pairing_code(&record, "audit-create-race")
        .expect("create pairing");
    db.conn
        .execute_batch(
            "
            CREATE TRIGGER simulate_remote_pairing_claim_race
            BEFORE UPDATE OF claimed_at ON remote_pairing_codes
            WHEN OLD.pairing_id = 'pairing-race'
                 AND OLD.claimed_at IS NULL
                 AND NEW.claimed_client_id = 'client-race'
                 AND NEW.claimed_at IS NOT NULL
            BEGIN
                UPDATE remote_pairing_codes
                   SET claimed_at = '2026-06-21T13:40:30Z',
                       claimed_client_id = NULL,
                       claim_remote_addr = '203.0.113.99'
                 WHERE pairing_id = OLD.pairing_id;
                SELECT RAISE(IGNORE);
            END;",
        )
        .expect("install race trigger");

    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-race",
        "MacBook Pro",
        "macos",
        Some("203.0.113.30"),
        "audit-claim-race",
    )
    .expect("claim request");
    let error = db
        .claim_remote_pairing_code(code.expose(), &claim, "2026-06-21T13:41:00Z")
        .expect_err("lost claim race must fail");

    assert!(
        error.to_string().contains("already claimed"),
        "unexpected race error: {error}"
    );
    let client_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_clients WHERE client_id = 'client-race'",
            [],
            |row| row.get(0),
        )
        .expect("client count");
    assert_eq!(client_count, 0);
    assert!(!db
        .load_remote_audit_events(10)
        .expect("audit events")
        .iter()
        .any(|event| event.event_id == "audit-claim-race"
            && event.outcome == RemoteAuditOutcome::Success));
}
