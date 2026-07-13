use sqlx::query_scalar;

use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
};

const ACTIVITY_TRIGGER: &str = "remote_audit_events_touch_client_activity";

#[test]
fn remote_client_activity_advances_monotonically_for_authenticated_audits() {
    let db = DaemonDb::open_in_memory().expect("open db");
    register_activity_client(&db, "active-client", "active-token");

    db.record_remote_audit_event(&activity_event(
        "activity-denied",
        "2026-07-13T12:45:00Z",
        Some("active-client"),
        RemoteAuditScopeDecision::Denied,
    ))
    .expect("record denied authenticated activity");
    assert_eq!(
        remote_client_last_seen_at(&db, "active-client").as_deref(),
        Some("2026-07-13T12:45:00Z")
    );

    db.record_remote_audit_event(&activity_event(
        "activity-older",
        "2026-07-13T12:44:00Z",
        Some("active-client"),
        RemoteAuditScopeDecision::Allowed,
    ))
    .expect("record older activity");
    assert_eq!(
        remote_client_last_seen_at(&db, "active-client").as_deref(),
        Some("2026-07-13T12:45:00Z"),
        "out-of-order audit persistence must not move activity backwards"
    );

    db.record_remote_audit_event(&activity_event(
        "activity-newer",
        "2026-07-13T12:46:00Z",
        Some("active-client"),
        RemoteAuditScopeDecision::Allowed,
    ))
    .expect("record newer activity");
    assert_eq!(
        remote_client_last_seen_at(&db, "active-client").as_deref(),
        Some("2026-07-13T12:46:00Z")
    );
}

#[test]
fn remote_client_activity_ignores_anonymous_and_revoked_audits() {
    let db = DaemonDb::open_in_memory().expect("open db");
    register_activity_client(&db, "inactive-client", "inactive-token");

    db.record_remote_audit_event(&activity_event(
        "activity-anonymous",
        "2026-07-13T12:45:00Z",
        None,
        RemoteAuditScopeDecision::Denied,
    ))
    .expect("record anonymous audit");
    assert_eq!(remote_client_last_seen_at(&db, "inactive-client"), None);

    db.record_remote_audit_event(&RemoteAuditEvent::new(
        "activity-management",
        "2026-07-13T12:45:30Z",
        None,
        Some("inactive-client"),
        "remote.clients.rotate",
        RemoteAccessScope::Admin,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        None,
        None,
    ))
    .expect("record client management audit");
    assert_eq!(
        remote_client_last_seen_at(&db, "inactive-client"),
        None,
        "management of a target client is not activity by that client"
    );

    db.revoke_remote_client("inactive-client", "2026-07-13T12:46:00Z")
        .expect("revoke client");
    db.record_remote_audit_event(&activity_event(
        "activity-revoked",
        "2026-07-13T12:47:00Z",
        Some("inactive-client"),
        RemoteAuditScopeDecision::Denied,
    ))
    .expect("record revoked client audit");
    assert_eq!(
        remote_client_last_seen_at(&db, "inactive-client"),
        None,
        "revoked credentials must not appear active"
    );
}

#[test]
fn remote_client_activity_migrates_v30_databases() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open current db");
        register_activity_client(&db, "migrated-client", "migrated-token");
    }
    let conn = Connection::open(&path).expect("open sqlite");
    conn.execute_batch(&format!(
        "DROP TRIGGER IF EXISTS {ACTIVITY_TRIGGER};
         UPDATE schema_meta SET value = '30' WHERE key = 'version';"
    ))
    .expect("downgrade to v30");
    drop(conn);

    let db = DaemonDb::open(&path).expect("migrate v30 database");
    assert_eq!(db.schema_version().expect("schema version"), "31");
    assert_eq!(activity_trigger_count(&db), 1);
    db.record_remote_audit_event(&activity_event(
        "activity-after-migration",
        "2026-07-13T12:48:00Z",
        Some("migrated-client"),
        RemoteAuditScopeDecision::Allowed,
    ))
    .expect("record activity after migration");
    assert_eq!(
        remote_client_last_seen_at(&db, "migrated-client").as_deref(),
        Some("2026-07-13T12:48:00Z")
    );
}

#[test]
fn remote_client_activity_repairs_a_missing_current_trigger() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open current db");
        register_activity_client(&db, "repaired-client", "repaired-token");
    }
    let conn = Connection::open(&path).expect("open sqlite");
    conn.execute_batch(&format!("DROP TRIGGER IF EXISTS {ACTIVITY_TRIGGER};"))
        .expect("drop activity trigger");
    drop(conn);

    let db = DaemonDb::open(&path).expect("repair current database");
    assert_eq!(activity_trigger_count(&db), 1);
    db.record_remote_audit_event(&activity_event(
        "activity-after-repair",
        "2026-07-13T12:49:00Z",
        Some("repaired-client"),
        RemoteAuditScopeDecision::Allowed,
    ))
    .expect("record activity after repair");
    assert_eq!(
        remote_client_last_seen_at(&db, "repaired-client").as_deref(),
        Some("2026-07-13T12:49:00Z")
    );
}

#[tokio::test]
async fn remote_client_activity_updates_through_async_audit_persistence() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open sync db");
        register_activity_client(&db, "async-client", "async-token");
    }
    let db = AsyncDaemonDb::connect(&path).await.expect("open async db");

    db.record_remote_audit_event(&activity_event(
        "activity-async",
        "2026-07-13T12:50:00Z",
        Some("async-client"),
        RemoteAuditScopeDecision::Allowed,
    ))
    .await
    .expect("record async activity");
    let last_seen_at = query_scalar::<_, Option<String>>(
        "SELECT last_seen_at FROM remote_clients WHERE client_id = ?1",
    )
    .bind("async-client")
    .fetch_one(db.pool())
    .await
    .expect("load async activity");
    assert_eq!(last_seen_at.as_deref(), Some("2026-07-13T12:50:00Z"));
}

fn register_activity_client(db: &DaemonDb, client_id: &str, token: &str) {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "Activity Client",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        token,
        "2026-07-13T12:40:00Z",
    )
    .expect("client registration");
    db.register_remote_client(&registration)
        .expect("register activity client");
}

fn activity_event(
    event_id: &str,
    recorded_at: &str,
    client_id: Option<&str>,
    decision: RemoteAuditScopeDecision,
) -> RemoteAuditEvent {
    RemoteAuditEvent::new(
        event_id,
        recorded_at,
        Some(event_id),
        client_id,
        "GET /v1/health",
        RemoteAccessScope::Read,
        decision,
        RemoteAuditOutcome::Success,
        Some("203.0.113.10"),
        None,
    )
}

fn remote_client_last_seen_at(db: &DaemonDb, client_id: &str) -> Option<String> {
    db.conn
        .query_row(
            "SELECT last_seen_at FROM remote_clients WHERE client_id = ?1",
            [client_id],
            |row| row.get(0),
        )
        .expect("load client activity")
}

fn activity_trigger_count(db: &DaemonDb) -> i64 {
    db.conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
            [ACTIVITY_TRIGGER],
            |row| row.get(0),
        )
        .expect("count activity trigger")
}
