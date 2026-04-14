use super::*;

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
fn migrates_v4_schema_to_agent_tuis() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let conn = Connection::open(&path).expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO schema_meta (key, value) VALUES ('version', '4');",
        )
        .expect("seed v4 schema meta");
    }

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);
    let exists: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'agent_tuis'",
            [],
            |row| row.get(0),
        )
        .expect("query agent_tuis table");
    assert_eq!(exists, 1);
}

#[test]
fn migrates_v5_schema_to_incremental_change_tracking() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let conn = Connection::open(&path).expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO schema_meta (key, value) VALUES ('version', '5');
                CREATE TABLE change_tracking (
                    scope TEXT PRIMARY KEY,
                    version INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO change_tracking (scope, version, updated_at)
                VALUES ('global', 3, '2026-04-13T12:00:00Z');",
        )
        .expect("seed v5 schema");
    }

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let (change_seq, last_seq): (i64, i64) = db
        .conn
        .query_row(
            "SELECT change_tracking.change_seq, change_tracking_state.last_seq
                 FROM change_tracking
                 JOIN change_tracking_state ON change_tracking_state.singleton = 1
                 WHERE change_tracking.scope = 'global'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("query migrated change tracking");

    assert_eq!(change_seq, 1);
    assert_eq!(last_seq, 1);
}

#[test]
fn migrates_v6_schema_to_timeline_ledger() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let conn = Connection::open(&path).expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO schema_meta (key, value) VALUES ('version', '6');
                CREATE TABLE projects (
                    project_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    project_dir TEXT,
                    repository_root TEXT,
                    checkout_id TEXT NOT NULL,
                    checkout_name TEXT NOT NULL,
                    context_root TEXT NOT NULL UNIQUE,
                    is_worktree INTEGER NOT NULL DEFAULT 0,
                    worktree_name TEXT,
                    origin_json TEXT,
                    discovered_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE sessions (
                    session_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(project_id),
                    schema_version INTEGER NOT NULL,
                    state_version INTEGER NOT NULL DEFAULT 0,
                    title TEXT NOT NULL DEFAULT '',
                    context TEXT NOT NULL,
                    status TEXT NOT NULL,
                    leader_id TEXT,
                    observe_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    last_activity_at TEXT,
                    archived_at TEXT,
                    pending_leader_transfer TEXT,
                    metrics_json TEXT NOT NULL DEFAULT '{}',
                    state_json TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 1
                ) WITHOUT ROWID;
                INSERT INTO projects (
                    project_id, name, project_dir, repository_root, checkout_id,
                    checkout_name, context_root, is_worktree, worktree_name,
                    origin_json, discovered_at, updated_at
                ) VALUES (
                    'project-1', 'harness', '/tmp/harness', '/tmp/harness', 'checkout',
                    'Repository', '/tmp/data/project-1', 0, NULL,
                    NULL, '2026-04-14T10:00:00Z', '2026-04-14T10:00:00Z'
                );
                INSERT INTO sessions (
                    session_id, project_id, schema_version, state_version, title, context,
                    status, leader_id, observe_id, created_at, updated_at, last_activity_at,
                    archived_at, pending_leader_transfer, metrics_json, state_json, is_active
                ) VALUES (
                    'sess-test-1', 'project-1', 3, 1, 'title', 'context',
                    'active', 'claude-leader', NULL, '2026-04-14T10:00:00Z',
                    '2026-04-14T10:00:00Z', NULL, NULL, NULL, '{}', '{}', 1
                );",
        )
        .expect("seed v6 schema");
    }

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let state: (i64, i64) = db
        .conn
        .query_row(
            "SELECT revision, entry_count
                 FROM session_timeline_state
                 WHERE session_id = 'sess-test-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("timeline state row");
    assert_eq!(state, (0, 0));
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
    conn.execute_batch(
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
            ",
    )
    .expect("create v2 schema");

    let event = sample_conversation_event(1, "duplicate");
    let event_json = serde_json::to_string(&event).expect("serialize conversation event");
    for _ in 0..3 {
        conn.execute(
            "INSERT INTO conversation_events
                    (session_id, agent_id, runtime, timestamp, sequence, kind, event_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                "sess-test-1",
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
