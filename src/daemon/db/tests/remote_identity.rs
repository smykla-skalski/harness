use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
};

#[test]
fn remote_identity_tables_exist_in_current_schema() {
    let db = DaemonDb::open_in_memory().expect("open db");
    for table in [
        "remote_clients",
        "remote_pairing_codes",
        "remote_audit_events",
        "remote_acme_state",
    ] {
        let count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?1",
                [table],
                |row| row.get(0),
            )
            .expect("query table");
        assert_eq!(count, 1, "missing table: {table}");
    }
}

#[test]
fn migrates_v26_schema_to_remote_identity_tables() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open current db");
        drop(db);
        let conn = Connection::open(&path).expect("open sqlite");
        conn.execute_batch(
            "DROP TABLE remote_acme_state;
             DROP TABLE remote_audit_events;
             DROP TABLE remote_pairing_codes;
             DROP TABLE remote_clients;
             UPDATE schema_meta SET value = '26' WHERE key = 'version';",
        )
        .expect("downgrade remote identity schema");
    }

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);
    let acme_state_rows: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM remote_acme_state WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .expect("remote acme state row");
    assert_eq!(acme_state_rows, 1);
}

#[test]
fn remote_clients_persist_hashed_tokens_and_support_revoke_rotate() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let registration = RemoteClientRegistration::new_for_tests(
        "client-1",
        "MacBook Pro",
        "macos",
        RemoteRole::Admin,
        &[],
        "remote-token-secret",
        "2026-06-21T12:40:00Z",
    )
    .expect("registration");

    let client = db
        .register_remote_client(&registration)
        .expect("register client");
    assert_eq!(client.client_id, "client-1");
    assert_eq!(
        client.scopes,
        vec![
            RemoteAccessScope::Read,
            RemoteAccessScope::Write,
            RemoteAccessScope::Admin
        ]
    );

    let stored_hash: String = db
        .conn
        .query_row(
            "SELECT token_hash FROM remote_clients WHERE client_id = 'client-1'",
            [],
            |row| row.get(0),
        )
        .expect("stored token hash");
    assert!(!stored_hash.contains("remote-token-secret"));
    assert!(
        db.verify_remote_client_token("client-1", "remote-token-secret")
            .expect("verify token")
            .is_some()
    );

    db.rotate_remote_client_token("client-1", "rotated-token-secret", "2026-06-21T12:41:00Z")
        .expect("rotate token");
    assert!(
        db.verify_remote_client_token("client-1", "remote-token-secret")
            .expect("old token rejected")
            .is_none()
    );
    assert!(
        db.verify_remote_client_token("client-1", "rotated-token-secret")
            .expect("new token accepted")
            .is_some()
    );

    db.revoke_remote_client("client-1", "2026-06-21T12:42:00Z")
        .expect("revoke client");
    assert!(
        db.verify_remote_client_token("client-1", "rotated-token-secret")
            .expect("revoked token rejected")
            .is_none()
    );
}

#[test]
fn remote_audit_events_persist_with_redacted_error_detail() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let event = RemoteAuditEvent::new(
        "remote-audit-1",
        "2026-06-21T12:45:00Z",
        Some("request-1"),
        Some("client-1"),
        "session.start",
        RemoteAccessScope::Write,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Failure,
        Some("203.0.113.10"),
        Some("backend failed token=remote-secret&retry=1"),
    );

    db.record_remote_audit_event(&event)
        .expect("record remote audit");
    let rows = db
        .load_remote_audit_events(10)
        .expect("load remote audit events");

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].event_id, "remote-audit-1");
    assert_eq!(
        rows[0].error_detail.as_deref(),
        Some("backend failed token=<redacted>&retry=1")
    );
}
