use super::*;

#[test]
fn bump_change_advances_monotonic_sequence() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("alpha").expect("first bump");
    db.bump_change("beta").expect("second bump");

    let alpha_seq: i64 = db
        .conn
        .query_row(
            "SELECT change_seq
                 FROM change_tracking
                 WHERE scope = 'session:alpha'",
            [],
            |row| row.get(0),
        )
        .expect("alpha change sequence");
    let beta_seq: i64 = db
        .conn
        .query_row(
            "SELECT change_seq
                 FROM change_tracking
                 WHERE scope = 'session:beta'",
            [],
            |row| row.get(0),
        )
        .expect("beta change sequence");
    let last_seq: i64 = db
        .conn
        .query_row(
            "SELECT last_seq
                 FROM change_tracking_state
                 WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .expect("last change sequence");

    assert_eq!(alpha_seq, 1);
    assert_eq!(beta_seq, 2);
    assert_eq!(last_seq, 2);
}

#[test]
fn bump_change_increments() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("global").expect("first bump");
    db.bump_change("global").expect("second bump");

    let version: i64 = db
        .conn
        .query_row(
            "SELECT version FROM change_tracking WHERE scope = 'global'",
            [],
            |row| row.get(0),
        )
        .expect("version");
    assert_eq!(version, 2);
}

#[test]
fn bump_change_creates_new_scope() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("session:test-1").expect("bump");

    let version: i64 = db
        .conn
        .query_row(
            "SELECT version FROM change_tracking WHERE scope = 'session:test-1'",
            [],
            |row| row.get(0),
        )
        .expect("version");
    assert_eq!(version, 1);
}

#[test]
fn bump_change_normalizes_raw_session_scope() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("test-1").expect("bump");

    let version: i64 = db
        .conn
        .query_row(
            "SELECT version FROM change_tracking WHERE scope = 'session:test-1'",
            [],
            |row| row.get(0),
        )
        .expect("version");
    assert_eq!(version, 1);
}

#[test]
fn append_daemon_event_inserts() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.append_daemon_event("2026-05-04T15:00:00Z", "info", "test message")
        .expect("append event");

    let count: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM daemon_events", [], |row| row.get(0))
        .expect("count events");
    assert_eq!(count, 1);
}
