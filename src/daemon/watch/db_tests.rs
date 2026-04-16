use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::index::DiscoveredProject;
use crate::session::service::build_new_session;

use super::loops::{CHANGE_TRACKING_POLL_SQL, poll_change_tracking, poll_change_tracking_async};
use super::refresh::{emit_watch_changes, emit_watch_changes_with};
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

#[tokio::test]
async fn poll_change_tracking_async_accepts_raw_session_scope() {
    let db_dir = tempdir().expect("tempdir");
    let db_path = db_dir.path().join("watch-async.db");
    let db = DaemonDb::open(&db_path).expect("open db");
    db.bump_change("watch-async-sess").expect("bump change");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async db");
    let mut last_change_seq = 0;
    let changes = poll_change_tracking_async(&async_db, &mut last_change_seq).await;

    assert!(changes.session_ids.contains("watch-async-sess"));
    assert_eq!(last_change_seq, 1);
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

#[tokio::test]
async fn emit_watch_changes_prefers_async_broadcast_builders() {
    let db_dir = tempdir().expect("tempdir");
    let db_path = db_dir.path().join("watch.db");
    let db = DaemonDb::open(&db_path).expect("open file db");
    let project = DiscoveredProject {
        project_id: "project-watch".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-watch".into(),
        checkout_name: "Repository".into(),
        context_root: "/tmp/harness-context".into(),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let state = build_new_session(
        "watch async snapshot",
        "",
        "watch-sess",
        "claude",
        Some("watch-session"),
        "2026-04-15T00:00:00Z",
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");
    drop(db);

    let async_db = Arc::new(
        AsyncDaemonDb::connect(&db_path)
            .await
            .expect("open async db"),
    );
    let (sender, mut receiver) = tokio::sync::broadcast::channel(8);

    emit_watch_changes(
        &sender,
        WatchChanges {
            sessions_updated: true,
            session_ids: BTreeSet::from([String::from("watch-sess")]),
        },
        None,
        Some(&async_db),
    )
    .await;

    assert_eq!(
        receiver.recv().await.expect("sessions_updated").event,
        "sessions_updated"
    );
    assert_eq!(
        receiver.recv().await.expect("session_updated").event,
        "session_updated"
    );
    assert_eq!(
        receiver.recv().await.expect("session_extensions").event,
        "session_extensions"
    );
}

#[test]
fn spawn_watch_loop_does_not_replay_historical_changes_on_startup() {
    let tmp = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(tmp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db_path = tmp.path().join("watch-startup.db");
            let db = Arc::new(Mutex::new(DaemonDb::open(&db_path).expect("open db")));
            {
                let db_guard = db.lock().expect("db lock");
                db_guard.bump_change("global").expect("bump global");
                db_guard
                    .bump_change("stale-session")
                    .expect("bump stale session");
            }

            let (sender, mut receiver) = tokio::sync::broadcast::channel(8);
            let async_db = Arc::new(std::sync::OnceLock::new());
            let handle =
                super::spawn_watch_loop(sender, Duration::from_millis(25), Some(db), async_db);

            let result = tokio::time::timeout(Duration::from_millis(150), receiver.recv()).await;
            handle.abort();

            assert!(
                result.is_err(),
                "historical change-tracking rows should not replay on startup: {result:?}"
            );
        });
    });
}
