use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

use crate::daemon::db::DaemonDb;

use super::loops::{CHANGE_TRACKING_POLL_SQL, poll_change_tracking};
use super::refresh::emit_watch_changes_with;
use super::state::WatchChanges;

#[test]
fn poll_change_tracking_accepts_raw_session_scope() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("watch-sess").expect("bump change");

    let mut last_change_seq = 0;
    let changes = poll_change_tracking(&db, &mut last_change_seq);

    assert!(changes.session_ids.contains("watch-sess"));
    assert_eq!(last_change_seq, 1);
}

#[test]
fn poll_change_tracking_uses_change_seq_index() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let details: Vec<String> = db
        .connection()
        .prepare(&format!("EXPLAIN QUERY PLAN {CHANGE_TRACKING_POLL_SQL}"))
        .expect("prepare explain")
        .query_map([0_i64], |row| row.get(3))
        .expect("query explain")
        .collect::<Result<_, _>>()
        .expect("collect explain");

    assert!(
        details
            .iter()
            .any(|detail| detail.contains("idx_change_tracking_change_seq")),
        "expected explain plan to use change_seq index, got {details:?}"
    );
}

#[test]
fn emit_watch_changes_releases_db_lock_before_extensions() {
    let db = Arc::new(Mutex::new(DaemonDb::open_in_memory().expect("open db")));
    let mut sessions_updated = false;
    let mut session_updated_core = false;
    let mut session_extensions = false;

    emit_watch_changes_with(
        WatchChanges {
            sessions_updated: true,
            session_ids: BTreeSet::from([String::from("watch-sess")]),
        },
        Some(&db),
        |db_ref| {
            sessions_updated = true;
            assert!(
                db_ref.is_some(),
                "core broadcasts should receive the DB view"
            );
        },
        |session_id, db_ref| {
            session_updated_core = true;
            assert_eq!(session_id, "watch-sess");
            assert!(db_ref.is_some(), "core updates should receive the DB view");
        },
        |session_id, db_ref| {
            session_extensions = true;
            assert_eq!(session_id, "watch-sess");
            assert!(
                db_ref.is_none(),
                "extensions should run after releasing the DB lock"
            );
            assert!(
                db.try_lock().is_ok(),
                "extensions should not inherit the core DB lock"
            );
        },
    );

    assert!(sessions_updated);
    assert!(session_updated_core);
    assert!(session_extensions);
}
