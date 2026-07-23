use super::super::remote_identity::REMOTE_AUDIT_EVENT_RETENTION_LIMIT;
use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
};
use rusqlite::params;

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
    assert!(
        db.rotate_remote_client_token("client-1", "   ", "2026-06-21T12:41:30Z")
            .is_err(),
        "blank rotated token should be rejected"
    );
    assert!(
        db.verify_remote_client_token("client-1", "rotated-token-secret")
            .expect("valid token remains accepted after rejected rotation")
            .is_some()
    );
    db.rotate_remote_client_token("client-1", "short", "2026-06-21T12:41:45Z")
        .expect("rotate to short token");
    let rotated_hint: String = db
        .conn
        .query_row(
            "SELECT token_hint FROM remote_clients WHERE client_id = 'client-1'",
            [],
            |row| row.get(0),
        )
        .expect("rotated token hint");
    assert_eq!(rotated_hint, "<redacted>");
    assert!(
        db.verify_remote_client_token("client-1", "short")
            .expect("short token accepted after redacted hint rotation")
            .is_some()
    );
    db.conn
        .execute(
            "UPDATE remote_clients SET token_hash = 'short' WHERE client_id = 'client-1'",
            [],
        )
        .expect("corrupt stored token hash");
    assert!(
        db.verify_remote_client_token("client-1", "short").is_err(),
        "clear-text stored hash must fail row loading instead of silently denying auth"
    );
    db.rotate_remote_client_token("client-1", "final-token-secret", "2026-06-21T12:41:50Z")
        .expect("restore valid token hash");
    assert!(
        db.verify_remote_client_token("client-1", "final-token-secret")
            .expect("restored token accepted")
            .is_some()
    );

    db.revoke_remote_client("client-1", "2026-06-21T12:42:00Z")
        .expect("revoke client");
    assert!(
        db.verify_remote_client_token("client-1", "final-token-secret")
            .expect("revoked token rejected")
            .is_none()
    );
}

#[test]
fn remote_client_session_rejects_revoke_and_token_rotation() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let registration = RemoteClientRegistration::new_for_tests(
        "session-client",
        "Session Client",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        "session-token",
        "2026-07-12T15:00:00Z",
    )
    .expect("registration");
    let authenticated = db
        .register_remote_client(&registration)
        .expect("register client");

    assert!(
        db.validate_remote_client_session(&authenticated)
            .expect("validate active session")
            .is_some()
    );

    db.rotate_remote_client_token(
        &authenticated.client_id,
        "rotated-session-token",
        "2026-07-12T15:01:00Z",
    )
    .expect("rotate token");
    assert!(
        db.validate_remote_client_session(&authenticated)
            .expect("validate rotated session")
            .is_none(),
        "a token rotation must invalidate the handshake identity"
    );

    let rotated = db
        .verify_remote_client_token(&authenticated.client_id, "rotated-session-token")
        .expect("verify rotated token")
        .expect("rotated client");
    db.revoke_remote_client(&rotated.client_id, "2026-07-12T15:02:00Z")
        .expect("revoke client");
    assert!(
        db.validate_remote_client_session(&rotated)
            .expect("validate revoked session")
            .is_none(),
        "revocation must invalidate the handshake identity"
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

#[test]
fn remote_audit_allowed_event_is_marked_failed_in_place() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let event = RemoteAuditEvent::new(
        "remote-audit-timeout",
        "2026-07-12T10:45:00Z",
        Some("request-timeout"),
        Some("client-1"),
        "GET /v1/health",
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        Some("203.0.113.10"),
        None,
    );
    db.record_remote_audit_event(&event)
        .expect("record allowed audit");

    db.mark_remote_audit_event_failed(
        "remote-audit-timeout",
        "request timeout authorization=Bearer-secret",
    )
    .expect("mark audit failed");
    let rows = db
        .load_remote_audit_events(10)
        .expect("load remote audit events");

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        rows[0].error_detail.as_deref(),
        Some("request timeout authorization=<redacted>")
    );
}

#[test]
fn remote_audit_retention_prunes_oldest_rows_deterministically_after_restart() {
    let temp = tempfile::tempdir().expect("create audit retention tempdir");
    let path = temp.path().join("harness.db");
    let retention_limit =
        usize::try_from(REMOTE_AUDIT_EVENT_RETENTION_LIMIT).expect("retention limit fits usize");
    drop(DaemonDb::open(&path).expect("initialize daemon database"));

    let conn = Connection::open(&path).expect("open audit retention database");
    let transaction = conn
        .unchecked_transaction()
        .expect("begin oversized audit seed transaction");
    for index in 0..=retention_limit + 1 {
        transaction
            .execute(
                "INSERT INTO remote_audit_events (
                    event_id, recorded_at, request_id, client_id, route_or_method,
                    scope, scope_decision, outcome, remote_addr, error_detail, metadata_json
                 ) VALUES (?1, '2026-07-22T12:00:00Z', NULL, NULL, 'GET /v1/health',
                           'read', 'denied', 'failure', NULL, NULL, '{}')",
                params![format!("retention-{index:05}")],
            )
            .expect("seed oversized remote audit row");
    }
    transaction.commit().expect("commit oversized audit seed");
    drop(conn);

    let db = DaemonDb::open(&path).expect("reopen and prune remote audits");
    let rows = db
        .load_remote_audit_events(u32::try_from(retention_limit).expect("limit fits u32"))
        .expect("load retained remote audits");
    let newest_retained = format!("retention-{:05}", retention_limit + 1);
    let oldest_retained = format!("retention-{:05}", 2);
    assert_eq!(rows.len(), retention_limit);
    assert_eq!(
        rows.first().map(|row| row.event_id.as_str()),
        Some(newest_retained.as_str())
    );
    assert_eq!(
        rows.last().map(|row| row.event_id.as_str()),
        Some(oldest_retained.as_str())
    );
    drop(db);

    let reopened = DaemonDb::open(&path).expect("restart after remote audit prune");
    let count: i64 = reopened
        .connection()
        .query_row("SELECT COUNT(*) FROM remote_audit_events", [], |row| {
            row.get(0)
        })
        .expect("count retained remote audits after restart");
    assert_eq!(count, REMOTE_AUDIT_EVENT_RETENTION_LIMIT);
}
