use super::schema_migrations::PROJECTS_AND_SESSIONS_V6_SCHEMA;
use super::*;
use std::sync::{Arc, Barrier};
use std::thread;

#[test]
fn open_in_memory_creates_schema() {
    let db = DaemonDb::open_in_memory().expect("open in-memory db");
    let version = db.schema_version().expect("schema version");
    assert_eq!(version, SCHEMA_VERSION);
}

#[test]
fn open_on_disk_creates_schema() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open db");
    let version = db.schema_version().expect("schema version");
    assert_eq!(version, SCHEMA_VERSION);
    assert!(path.exists());
}

#[test]
fn open_existing_db_is_idempotent() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    let db1 = DaemonDb::open(&path).expect("first open");
    assert_eq!(db1.schema_version().expect("version"), SCHEMA_VERSION);
    drop(db1);

    let db2 = DaemonDb::open(&path).expect("second open");
    assert_eq!(db2.schema_version().expect("version"), SCHEMA_VERSION);
}

#[test]
fn migration_creates_policy_graph_tables() {
    let db = DaemonDb::open_in_memory().expect("open in-memory db");
    let conn = db.connection();
    for table in [
        "policy_workspace",
        "policy_canvases",
        "policy_nodes",
        "policy_edges",
        "policy_groups",
        "policy_group_nodes",
    ] {
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get(0),
            )
            .expect("query policy table existence");
        assert_eq!(count, 1, "policy table {table} should exist after migration");
    }
}

#[test]
fn concurrent_open_on_fresh_db_serializes_schema_bootstrap() {
    struct SchemaInitHookGuard;

    impl SchemaInitHookGuard {
        fn install(hook: Arc<dyn Fn() + Send + Sync + 'static>) -> Self {
            set_schema_init_hook(Some(hook));
            Self
        }
    }

    impl Drop for SchemaInitHookGuard {
        fn drop(&mut self) {
            set_schema_init_hook(None);
        }
    }

    let _hook = SchemaInitHookGuard::install(Arc::new(|| {
        thread::sleep(Duration::from_millis(50));
    }));

    for attempt in 0..4 {
        let tmp = tempfile::tempdir().expect("tempdir");
        let path = tmp.path().join(format!("harness-{attempt}.db"));
        let start = Arc::new(Barrier::new(8));
        let mut handles = Vec::new();

        for _ in 0..8 {
            let path = path.clone();
            let start = Arc::clone(&start);
            handles.push(thread::spawn(move || {
                start.wait();
                let db = DaemonDb::open(&path).expect("open concurrent db");
                db.schema_version().expect("schema version")
            }));
        }

        for handle in handles {
            assert_eq!(handle.join().expect("join open thread"), SCHEMA_VERSION);
        }
    }
}

#[test]
fn all_tables_exist() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let tables: Vec<String> = db
        .conn
        .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        .expect("prepare")
        .query_map([], |row| row.get(0))
        .expect("query")
        .filter_map(Result::ok)
        .collect();

    let expected = [
        "agent_activity_cache",
        "agent_tuis",
        "agents",
        "change_tracking",
        "change_tracking_state",
        "codex_runs",
        "conversation_events",
        "daemon_events",
        "diagnostics_cache",
        "projects",
        "schema_meta",
        "session_log",
        "session_timeline_entries",
        "session_timeline_state",
        "sessions",
        "signal_index",
        "task_checkpoints",
        "tasks",
    ];
    for table in expected {
        assert!(
            tables.contains(&table.to_string()),
            "missing table: {table}"
        );
    }
}

#[test]
fn fresh_schema_agents_table_includes_managed_agent_identity_columns() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let columns = agent_columns(&db.conn);
    assert!(columns.iter().any(|column| column == "managed_agent_kind"));
    assert!(columns.iter().any(|column| column == "managed_agent_id"));
}

#[test]
fn fresh_schema_codex_runs_table_includes_agent_parity_columns() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let columns = codex_run_columns(&db.conn);
    for expected in [
        "session_agent_id",
        "display_name",
        "model",
        "effort",
        "resolved_approvals_json",
        "events_json",
    ] {
        assert!(
            columns.iter().any(|column| column == expected),
            "missing codex_runs column: {expected}"
        );
    }
}

#[test]
fn migrates_v10_schema_adds_managed_agent_identity_columns_without_backfilling_rows() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    {
        let db = DaemonDb::open(&path).expect("open fresh db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state_with_managed_agents();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");
        simulate_pre_v11_agents_table(&db.conn);
    }

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let columns = agent_columns(&db.conn);
    assert!(columns.iter().any(|column| column == "managed_agent_kind"));
    assert!(columns.iter().any(|column| column == "managed_agent_id"));

    assert_eq!(
        session_agent_identity_rows(&db.conn, "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4"),
        vec![
            ("acp-worker".into(), None, None),
            ("claude-leader".into(), None, None),
            ("codex-worker".into(), None, None),
            ("unmanaged-reviewer".into(), None, None),
        ]
    );

    let (name, runtime, session_key): (String, String, Option<String>) = db
        .conn
        .query_row(
            "SELECT name, runtime, agent_session_id
             FROM agents
             WHERE session_id = ?1 AND agent_id = ?2",
            rusqlite::params!["f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4", "claude-leader"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load migrated agent row");
    assert_eq!(name, "Claude Leader");
    assert_eq!(runtime, "claude");
    assert_eq!(
        session_key.as_deref(),
        Some("2a35c8f7-e812-5024-aed6-9f3b6318847e")
    );
}

#[test]
fn migrates_v12_schema_adds_codex_agent_parity_columns_with_defaults() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    {
        let db = DaemonDb::open(&path).expect("open fresh db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");
        simulate_pre_v13_codex_runs_table(&db.conn);
    }

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let columns = codex_run_columns(&db.conn);
    for expected in [
        "session_agent_id",
        "display_name",
        "model",
        "effort",
        "resolved_approvals_json",
        "events_json",
    ] {
        assert!(
            columns.iter().any(|column| column == expected),
            "missing codex_runs column after migration: {expected}"
        );
    }

    let defaults: (
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        String,
    ) = db
        .conn
        .query_row(
            "SELECT session_agent_id, display_name, model, effort,
                    resolved_approvals_json, events_json
             FROM codex_runs
             WHERE run_id = 'codex-run-legacy'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .expect("load migrated codex run");

    assert_eq!(defaults, (None, None, None, None, "[]".into(), "[]".into()));
}

#[test]
fn wal_mode_is_active() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open db");
    let mode: String = db
        .conn
        .pragma_query_value(None, "journal_mode", |row| row.get(0))
        .expect("journal_mode");
    assert_eq!(mode, "wal");
}

#[test]
fn foreign_keys_are_enabled() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let enabled: i64 = db
        .conn
        .pragma_query_value(None, "foreign_keys", |row| row.get(0))
        .expect("foreign_keys");
    assert_eq!(enabled, 1);
}

#[test]
fn change_tracking_seeded() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let (version, change_seq): (i64, i64) = db
        .conn
        .query_row(
            "SELECT version, change_seq
                 FROM change_tracking
                 WHERE scope = 'global'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("global version");
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
    assert_eq!(version, 0);
    assert_eq!(change_seq, 0);
    assert_eq!(last_seq, 0);
}
#[test]
fn open_migrates_v2_db_and_deduplicates_event_indexes() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    let conn = Connection::open(&path).expect("open raw db");
    conn.execute_batch(&format!(
        "
            CREATE TABLE schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;
            INSERT INTO schema_meta (key, value) VALUES ('version', '2');

            CREATE TABLE daemon_events (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at TEXT NOT NULL,
                level       TEXT NOT NULL,
                message     TEXT NOT NULL
            );

            CREATE TABLE conversation_events (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   TEXT NOT NULL,
                agent_id     TEXT NOT NULL,
                runtime      TEXT NOT NULL,
                timestamp    TEXT,
                sequence     INTEGER NOT NULL DEFAULT 0,
                kind         TEXT NOT NULL,
                event_json   TEXT NOT NULL
            );

            {PROJECTS_AND_SESSIONS_V6_SCHEMA}
            ",
    ))
    .expect("create v2 schema");

    let event = sample_conversation_event(1, "duplicate");
    let event_json = serde_json::to_string(&event).expect("serialize conversation event");
    for _ in 0..3 {
        conn.execute(
            "INSERT INTO conversation_events
                    (session_id, agent_id, runtime, timestamp, sequence, kind, event_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
                "claude-leader",
                "claude",
                event.timestamp.clone(),
                i64_from_u64(event.sequence),
                "AssistantText",
                event_json.clone(),
            ],
        )
        .expect("insert duplicate conversation event");
    }
    for _ in 0..4 {
        conn.execute(
            "INSERT INTO daemon_events (recorded_at, level, message)
                 VALUES (?1, ?2, ?3)",
            rusqlite::params!["2026-04-03T12:00:00Z", "info", "duplicate"],
        )
        .expect("insert duplicate daemon event");
    }
    drop(conn);

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("schema version"), SCHEMA_VERSION);

    let conversation_count: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM conversation_events", [], |row| {
            row.get(0)
        })
        .expect("count migrated conversation events");
    assert_eq!(conversation_count, 1);

    let daemon_count: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM daemon_events", [], |row| row.get(0))
        .expect("count migrated daemon events");
    assert_eq!(daemon_count, 1);
}

fn codex_run_columns(conn: &Connection) -> Vec<String> {
    conn.prepare("PRAGMA table_info(codex_runs)")
        .expect("prepare codex_runs table info")
        .query_map([], |row| row.get(1))
        .expect("query codex_runs table info")
        .collect::<Result<Vec<_>, _>>()
        .expect("collect codex_runs table columns")
}

fn simulate_pre_v13_codex_runs_table(conn: &Connection) {
    conn.execute_batch(
        "DROP INDEX IF EXISTS idx_codex_runs_session_updated;
         DROP INDEX IF EXISTS idx_codex_runs_status;
         DROP TABLE codex_runs;
         CREATE TABLE codex_runs (
             run_id                 TEXT PRIMARY KEY,
             session_id             TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
             project_dir            TEXT NOT NULL,
             thread_id              TEXT,
             turn_id                TEXT,
             mode                   TEXT NOT NULL,
             status                 TEXT NOT NULL,
             prompt                 TEXT NOT NULL,
             latest_summary         TEXT,
             final_message          TEXT,
             error                  TEXT,
             pending_approvals_json TEXT NOT NULL DEFAULT '[]',
             created_at             TEXT NOT NULL,
             updated_at             TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE INDEX idx_codex_runs_session_updated
             ON codex_runs(session_id, updated_at DESC);
         CREATE INDEX idx_codex_runs_status
             ON codex_runs(status);
         INSERT INTO codex_runs (
             run_id, session_id, project_dir, thread_id, turn_id, mode, status,
             prompt, latest_summary, final_message, error, pending_approvals_json,
             created_at, updated_at
         ) VALUES (
             'codex-run-legacy',
             'f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4',
             '/tmp/harness',
             'thread-legacy',
             'turn-legacy',
             'approval',
             'completed',
             'Investigate the suite.',
             'Done',
             'Fixed.',
             NULL,
             '[]',
             '2026-04-09T09:00:00Z',
             '2026-04-09T09:05:00Z'
         );
         UPDATE schema_meta SET value = '12' WHERE key = 'version';",
    )
    .expect("simulate pre-v13 codex_runs table");
}
