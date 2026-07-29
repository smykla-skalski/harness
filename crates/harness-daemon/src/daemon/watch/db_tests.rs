use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tempfile::tempdir;
use tokio::sync::broadcast::Sender;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb, session_status_db_label};
use crate::daemon::index::DiscoveredProject;
use crate::daemon::protocol::StreamEvent;
use crate::session::service::build_new_session;
use crate::session::types::SessionStatus;
use crate::workspace::utc_now;
use harness_kernel::errors::CliError;

use super::loops::{
    CHANGE_TRACKING_POLL_SQL, liveness_reconcile_due, poll_change_tracking,
    poll_change_tracking_async,
};
use super::refresh::{emit_watch_changes, emit_watch_changes_with};
use super::service_port::WatchServicePort;
use super::state::WatchChanges;

/// Mirrors `service::SESSION_LIVENESS_REFRESH_TTL` for tests that exercise the
/// loop's own due-or-not arithmetic; `watch` takes the real value as a
/// `WatchServicePort` parameter instead of reading it off `service`.
const TEST_LIVENESS_REFRESH_TTL: Duration = Duration::from_secs(5);

/// A `WatchServicePort` double that sends a same-named, empty-payload
/// `StreamEvent` for every broadcast call instead of resolving real session
/// data. The tests using it assert event names and ordering, not payload
/// content, so this is enough to exercise `watch`'s own orchestration without
/// pulling `service`'s broadcast logic into a `watch` test.
struct RecordingWatchServicePort;

#[async_trait]
impl WatchServicePort for RecordingWatchServicePort {
    fn liveness_refresh_ttl(&self) -> Duration {
        TEST_LIVENESS_REFRESH_TTL
    }

    fn reconcile_liveness(&self, _db: Option<&DaemonDb>) -> Result<(), CliError> {
        Ok(())
    }

    async fn reconcile_liveness_async(
        &self,
        _async_db: Option<&AsyncDaemonDb>,
    ) -> Result<(), CliError> {
        Ok(())
    }

    fn broadcast_sessions_updated(&self, sender: &Sender<StreamEvent>, _db: Option<&DaemonDb>) {
        send_stub_event(sender, "sessions_updated", None);
    }

    fn broadcast_session_updated_core(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        _db: Option<&DaemonDb>,
    ) {
        send_stub_event(sender, "session_updated", Some(session_id));
    }

    fn broadcast_session_extensions(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        _db: Option<&DaemonDb>,
    ) {
        send_stub_event(sender, "session_extensions", Some(session_id));
    }

    async fn broadcast_sessions_updated_async(
        &self,
        sender: &Sender<StreamEvent>,
        _async_db: Option<&AsyncDaemonDb>,
    ) {
        send_stub_event(sender, "sessions_updated", None);
    }

    async fn broadcast_session_updated_core_async(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        _async_db: Option<&AsyncDaemonDb>,
    ) {
        send_stub_event(sender, "session_updated", Some(session_id));
    }

    async fn broadcast_session_extensions_async(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        _async_db: Option<&AsyncDaemonDb>,
    ) {
        send_stub_event(sender, "session_extensions", Some(session_id));
    }
}

fn send_stub_event(sender: &Sender<StreamEvent>, event: &str, session_id: Option<&str>) {
    let _ = sender.send(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serde_json::Value::Null,
    });
}

#[test]
fn poll_change_tracking_accepts_raw_session_scope() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")
        .expect("bump change");

    let mut last_change_seq = 0;
    let changes = poll_change_tracking(&db, &mut last_change_seq);

    assert!(
        changes
            .session_ids
            .contains("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")
    );
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
            session_ids: BTreeSet::from([String::from("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")]),
            ..WatchChanges::default()
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
            assert_eq!(session_id, "ae60b5c5-37cf-5a50-a816-8f454bb9e92e");
            assert!(db_ref.is_some(), "core updates should receive the DB view");
        },
        |session_id, db_ref| {
            session_extensions = true;
            assert_eq!(session_id, "ae60b5c5-37cf-5a50-a816-8f454bb9e92e");
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
            session_ids: BTreeSet::from([String::from("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")]),
            ..WatchChanges::default()
        },
        None,
        Some(&async_db),
        &RecordingWatchServicePort,
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
            let handle = super::spawn_watch_loop(
                sender,
                Duration::from_millis(25),
                Some(db),
                async_db,
                Arc::new(RecordingWatchServicePort),
            );

            let result = tokio::time::timeout(Duration::from_millis(150), receiver.recv()).await;
            handle.abort();

            assert!(
                result.is_err(),
                "historical change-tracking rows should not replay on startup: {result:?}"
            );
        });
    });
}

#[test]
fn liveness_reconcile_due_runs_on_any_session_activity() {
    let now = Instant::now();

    let global = WatchChanges {
        sessions_updated: true,
        session_ids: BTreeSet::new(),
        ..WatchChanges::default()
    };
    assert!(liveness_reconcile_due(
        &global,
        Some(now),
        now,
        TEST_LIVENESS_REFRESH_TTL
    ));

    let scoped = WatchChanges {
        sessions_updated: false,
        session_ids: BTreeSet::from([String::from("ae60b5c5-37cf-5a50-a816-8f454bb9e92e")]),
        ..WatchChanges::default()
    };
    assert!(liveness_reconcile_due(
        &scoped,
        Some(now),
        now,
        TEST_LIVENESS_REFRESH_TTL
    ));
}

#[test]
fn liveness_reconcile_due_first_tick_runs_then_gates_idle_on_ttl() {
    let now = Instant::now();
    let idle = WatchChanges::default();

    assert!(
        liveness_reconcile_due(&idle, None, now, TEST_LIVENESS_REFRESH_TTL),
        "the first idle tick must reconcile to establish a baseline"
    );
    assert!(
        !liveness_reconcile_due(&idle, Some(now), now, TEST_LIVENESS_REFRESH_TTL),
        "an idle tick within the TTL must skip the sweep"
    );

    let past_ttl = now
        .checked_add(TEST_LIVENESS_REFRESH_TTL + Duration::from_secs(1))
        .expect("instant within range");
    assert!(
        liveness_reconcile_due(&idle, Some(now), past_ttl, TEST_LIVENESS_REFRESH_TTL),
        "an idle tick past the TTL must reconcile so dead-process detection stays bounded"
    );
}

#[test]
fn liveness_candidate_status_labels_match_eligible_statuses() {
    assert_eq!(
        session_status_db_label(SessionStatus::AwaitingLeader).expect("label"),
        "awaiting_leader"
    );
    assert_eq!(
        session_status_db_label(SessionStatus::Active).expect("label"),
        "active"
    );
    assert_eq!(
        session_status_db_label(SessionStatus::LeaderlessDegraded).expect("label"),
        "leaderless_degraded"
    );
}

#[test]
fn list_liveness_candidate_ids_filters_on_status_and_agents() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = DiscoveredProject {
        project_id: "project-liveness".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-liveness".into(),
        checkout_name: "main".into(),
        context_root: "/tmp/harness-context".into(),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");

    // Awaiting-leader session with no agents: eligible status, but excluded by
    // the agent-count filter.
    let idle = build_new_session(
        "idle",
        "",
        "11111111-1111-5111-8111-111111111111",
        "claude",
        None,
        "2026-04-15T00:00:00Z",
    );
    db.sync_session(&project.project_id, &idle)
        .expect("sync idle session");

    // Active session with a leader and one agent: a liveness candidate.
    let mut live = build_new_session(
        "live",
        "",
        "22222222-2222-5222-8222-222222222222",
        "claude",
        None,
        "2026-04-15T00:00:00Z",
    );
    live.status = SessionStatus::Active;
    live.leader_id = Some("leader-agent".into());
    live.metrics.agent_count = 1;
    db.sync_session(&project.project_id, &live)
        .expect("sync live session");

    let candidates = db
        .list_liveness_candidate_ids()
        .expect("liveness candidates");
    assert_eq!(
        candidates,
        vec![String::from("22222222-2222-5222-8222-222222222222")]
    );
}
