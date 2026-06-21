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
    assert!(
        db.verify_remote_client_token("client-1", claimed.bearer_token.expose())
            .expect("verify paired client")
            .is_some()
    );
    let replay_claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-1",
        "MacBook Pro",
        "macos",
        Some("203.0.113.10"),
        "audit-claim-replay",
    )
    .expect("replay claim request");
    assert!(
        db.claim_remote_pairing_code(code.expose(), &replay_claim, "2026-06-21T13:42:00Z")
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
    assert!(routes.contains(&"remote.pair.replay".to_string()));
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

    let events = db.load_remote_audit_events(10).expect("audit events");
    let routes: Vec<_> = events
        .iter()
        .map(|event| event.route_or_method.clone())
        .collect();
    let expired_event = events
        .iter()
        .find(|event| event.route_or_method == "remote.pair.expire")
        .expect("expiry audit event");
    let domain_event = events
        .iter()
        .find(|event| event.route_or_method == "remote.pair.domain")
        .expect("domain audit event");

    assert_eq!(expired_event.client_id.as_deref(), Some("client-expired"));
    assert_eq!(
        domain_event.client_id.as_deref(),
        Some("client-wrong-domain")
    );
    assert!(routes.contains(&"remote.pair.expire".to_string()));
    assert!(routes.contains(&"remote.pair.domain".to_string()));
}

#[test]
fn remote_pairing_claim_failures_record_claimed_client_id() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-invalid",
        "MacBook Pro",
        "macos",
        Some("203.0.113.50"),
        "audit-client-invalid",
    )
    .expect("claim request");
    assert!(
        db.claim_remote_pairing_code(" ", &claim, "2026-06-21T13:41:00Z")
            .is_err(),
        "blank code must fail"
    );

    let invalid_event = db
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .find(|event| event.route_or_method == "remote.pair.invalid")
        .expect("invalid audit event");

    assert_eq!(invalid_event.client_id.as_deref(), Some("client-invalid"));
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
    assert!(
        !db.load_remote_audit_events(10)
            .expect("audit events")
            .iter()
            .any(|event| event.event_id == "audit-claim-race"
                && event.outcome == RemoteAuditOutcome::Success)
    );
}

#[test]
fn remote_pairing_claim_rolls_back_client_and_pairing_when_audit_fails() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("atomic-pairing-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-atomic",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");
    db.create_remote_pairing_code(&record, "audit-create-atomic")
        .expect("create pairing");
    db.conn
        .execute_batch(
            "
            CREATE TRIGGER fail_remote_pairing_claim_audit
            BEFORE INSERT ON remote_audit_events
            WHEN NEW.event_id = 'audit-claim-atomic'
            BEGIN
                SELECT RAISE(FAIL, 'simulated audit failure');
            END;",
        )
        .expect("install audit failure trigger");

    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-atomic",
        "MacBook Pro",
        "macos",
        Some("203.0.113.40"),
        "audit-claim-atomic",
    )
    .expect("claim request");
    assert!(
        db.claim_remote_pairing_code(code.expose(), &claim, "2026-06-21T13:41:00Z")
            .is_err(),
        "audit failure must reject the claim"
    );

    let client_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_clients WHERE client_id = 'client-atomic'",
            [],
            |row| row.get(0),
        )
        .expect("client count");
    let claimed_at: Option<String> = db
        .conn
        .query_row(
            "SELECT claimed_at FROM remote_pairing_codes WHERE pairing_id = 'pairing-atomic'",
            [],
            |row| row.get(0),
        )
        .expect("claimed at");

    assert_eq!(client_count, 0);
    assert!(claimed_at.is_none());
}

#[test]
fn remote_pairing_create_rolls_back_pairing_when_audit_fails() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute_batch(
            "
            CREATE TRIGGER fail_remote_pairing_create_audit
            BEFORE INSERT ON remote_audit_events
            WHEN NEW.event_id = 'audit-create-fail'
            BEGIN
                SELECT RAISE(FAIL, 'simulated create audit failure');
            END;",
        )
        .expect("install audit failure trigger");
    let code = RemotePairingCode::from_value_for_tests("create-rollback-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-create-rollback",
        RemoteRole::Viewer,
        &[],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");

    assert!(
        db.create_remote_pairing_code(&record, "audit-create-fail")
            .is_err(),
        "create audit failure must reject pairing creation"
    );
    let pairing_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_pairing_codes
              WHERE pairing_id = 'pairing-create-rollback'",
            [],
            |row| row.get(0),
        )
        .expect("pairing count");

    assert_eq!(pairing_count, 0);
}

#[test]
fn remote_pairing_create_rejects_blank_audit_event_id_before_writes() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("blank-create-audit-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-create-blank-audit",
        RemoteRole::Viewer,
        &[],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");

    assert!(
        db.create_remote_pairing_code(&record, " \t").is_err(),
        "blank audit event ids must be rejected before pairing creation"
    );
    let pairing_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_pairing_codes
              WHERE pairing_id = 'pairing-create-blank-audit'",
            [],
            |row| row.get(0),
        )
        .expect("pairing count");
    let audit_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_audit_events WHERE event_id = ''",
            [],
            |row| row.get(0),
        )
        .expect("blank audit count");

    assert_eq!(pairing_count, 0);
    assert_eq!(audit_count, 0);
}

#[test]
fn remote_pairing_claim_rejects_blank_audit_event_id_before_writes() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("blank-claim-audit-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-claim-blank-audit",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-06-21T13:40:00Z",
        "2026-06-21T13:50:00Z",
    )
    .expect("pairing record");
    db.create_remote_pairing_code(&record, "audit-create-blank-claim")
        .expect("create pairing");
    let mut claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-blank-audit",
        "MacBook Pro",
        "macos",
        Some("203.0.113.60"),
        "audit-claim-blank-placeholder",
    )
    .expect("claim request");
    claim.audit_event_id = " \t".to_string();

    assert!(
        db.claim_remote_pairing_code(code.expose(), &claim, "2026-06-21T13:41:00Z")
            .is_err(),
        "blank claim audit event ids must be rejected before claim writes"
    );
    let client_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_clients
              WHERE client_id = 'client-blank-audit'",
            [],
            |row| row.get(0),
        )
        .expect("client count");
    let claimed_at: Option<String> = db
        .conn
        .query_row(
            "SELECT claimed_at FROM remote_pairing_codes
              WHERE pairing_id = 'pairing-claim-blank-audit'",
            [],
            |row| row.get(0),
        )
        .expect("claimed at");
    let audit_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_audit_events WHERE event_id = ''",
            [],
            |row| row.get(0),
        )
        .expect("blank audit count");

    assert_eq!(client_count, 0);
    assert!(claimed_at.is_none());
    assert_eq!(audit_count, 0);
}

#[test]
fn remote_pairing_claim_audits_invalid_and_unknown_code_routes() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-invalid",
        "MacBook Pro",
        "macos",
        Some("203.0.113.50"),
        "audit-claim-blank",
    )
    .expect("claim request");
    assert!(
        db.claim_remote_pairing_code(" ", &claim, "2026-06-21T13:41:00Z")
            .is_err(),
        "blank code must fail"
    );
    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "client-unknown",
        "MacBook Pro",
        "macos",
        Some("203.0.113.51"),
        "audit-claim-unknown",
    )
    .expect("claim request");
    assert!(
        db.claim_remote_pairing_code("unknown-code", &claim, "2026-06-21T13:42:00Z")
            .is_err(),
        "unknown code must fail"
    );

    let routes: Vec<_> = db
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert!(routes.contains(&"remote.pair.invalid".to_string()));
    assert!(routes.contains(&"remote.pair.unknown".to_string()));
}
