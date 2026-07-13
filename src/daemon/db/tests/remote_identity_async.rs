use tempfile::tempdir;

use super::{AsyncDaemonDb, DaemonDb};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
};

const CLIENT_ID: &str = "async-revoke-client";
const TOKEN: &str = "async-revoke-token-secret";

#[tokio::test]
async fn remote_client_revoke_rolls_back_when_audit_insert_fails() {
    let temp = tempdir().expect("create remote identity tempdir");
    let db_path = temp.path().join("harness.db");
    let db = DaemonDb::open(&db_path).expect("open daemon db");
    register_client(&db);
    let duplicate = revoke_audit(CLIENT_ID, "duplicate-revoke-audit");
    db.record_remote_audit_event(&duplicate)
        .expect("seed duplicate audit id");
    drop(db);
    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");

    async_db
        .revoke_remote_client_with_audit(CLIENT_ID, "2026-07-13T18:00:00Z", &duplicate)
        .await
        .expect_err("duplicate audit insert should fail the transaction");

    let db = DaemonDb::open(&db_path).expect("reopen daemon db");
    assert!(
        db.verify_remote_client_token(CLIENT_ID, TOKEN)
            .expect("verify client after rollback")
            .is_some(),
        "audit failure must roll back client revocation"
    );
}

#[tokio::test]
async fn remote_client_revoke_rejects_mismatched_audit_identity() {
    let temp = tempdir().expect("create remote identity tempdir");
    let db_path = temp.path().join("harness.db");
    let db = DaemonDb::open(&db_path).expect("open daemon db");
    register_client(&db);
    drop(db);
    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let audit = revoke_audit("different-client", "mismatched-revoke-audit");

    async_db
        .revoke_remote_client_with_audit(CLIENT_ID, "2026-07-13T18:01:00Z", &audit)
        .await
        .expect_err("mismatched audit identity should fail");

    let db = DaemonDb::open(&db_path).expect("reopen daemon db");
    assert!(
        db.verify_remote_client_token(CLIENT_ID, TOKEN)
            .expect("verify client after mismatch")
            .is_some()
    );
}

fn register_client(db: &DaemonDb) {
    let registration = RemoteClientRegistration::new_for_tests(
        CLIENT_ID,
        "Async revoke client",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        TOKEN,
        "2026-07-13T17:55:00Z",
    )
    .expect("remote client registration");
    db.register_remote_client(&registration)
        .expect("register remote client");
}

fn revoke_audit(client_id: &str, event_id: &str) -> RemoteAuditEvent {
    RemoteAuditEvent::new(
        event_id,
        "2026-07-13T18:00:00Z",
        Some("remote-revoke-request"),
        Some(client_id),
        "remote.clients.self_revoke",
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        None,
        None,
    )
}
