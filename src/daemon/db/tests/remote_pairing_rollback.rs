//! Rollback coverage for the remote pairing writes.
//!
//! Every test here forces an audit insert to fail and asserts nothing
//! claimable survives it. Split out of `remote_pairing.rs` to keep both files
//! under the repo's Rust source length limit.

use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision,
};
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingCode, RemotePairingRecord,
};

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

/// A caller that records its own audit event after creation cannot fail closed:
/// the link is already committed, so the error it returns invites a retry that
/// mints a second valid link. The extra event therefore shares the transaction.
#[test]
fn remote_pairing_create_rolls_back_when_the_extra_audit_fails() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let code = RemotePairingCode::from_value_for_tests("mint-atomic-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-mint-atomic",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-07-25T13:40:00Z",
        "2026-07-25T13:50:00Z",
    )
    .expect("pairing record");
    db.conn
        .execute_batch(
            "
            CREATE TRIGGER fail_remote_pairing_mint_audit
            BEFORE INSERT ON remote_audit_events
            WHEN NEW.event_id = 'audit-mint-atomic'
            BEGIN
                SELECT RAISE(FAIL, 'simulated mint audit failure');
            END;",
        )
        .expect("install audit failure trigger");
    let mint_audit = RemoteAuditEvent::new(
        "audit-mint-atomic",
        "2026-07-25T13:40:00Z",
        Some("request-mint-atomic"),
        Some("panel-broker"),
        "remote.pair.mint",
        RemoteAccessScope::PairMint,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        None,
        None,
    );

    db.create_remote_pairing_code_with_audit(&record, "audit-create-mint", Some(&mint_audit))
        .expect_err("a failed mint audit must fail the whole create");

    let pairings: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM remote_pairing_codes", [], |row| {
            row.get(0)
        })
        .expect("pairing count");
    assert_eq!(pairings, 0, "no claimable link may survive a failed audit");
    let audits: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM remote_audit_events", [], |row| {
            row.get(0)
        })
        .expect("audit count");
    assert_eq!(audits, 0, "the create audit must roll back with it");
}
