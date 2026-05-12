use super::*;

/// Minimal `projects` + `sessions` DDL that the v6 -> v7 migration expects to
/// exist before it can seed the timeline ledger.
const PROJECTS_AND_SESSIONS_V6_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS projects (
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
    CREATE TABLE IF NOT EXISTS sessions (
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
    ) WITHOUT ROWID;";

#[test]
fn migrates_v4_schema_to_agent_tuis() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let conn = Connection::open(&path).expect("open sqlite");
        conn.execute_batch(&format!(
            "CREATE TABLE schema_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO schema_meta (key, value) VALUES ('version', '4');
                {PROJECTS_AND_SESSIONS_V6_SCHEMA}"
        ))
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
        conn.execute_batch(&format!(
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
                VALUES ('global', 3, '2026-04-13T12:00:00Z');
                {PROJECTS_AND_SESSIONS_V6_SCHEMA}"
        ))
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
                    'main', '/tmp/data/project-1', 0, NULL,
                    NULL, '2026-04-14T10:00:00Z', '2026-04-14T10:00:00Z'
                );
                INSERT INTO sessions (
                    session_id, project_id, schema_version, state_version, title, context,
                    status, leader_id, observe_id, created_at, updated_at, last_activity_at,
                    archived_at, pending_leader_transfer, metrics_json, state_json, is_active
                ) VALUES (
                    'f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4', 'project-1', 3, 1, 'title', 'context',
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
                 WHERE session_id = 'f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("timeline state row");
    assert_eq!(state, (0, 0));
}
