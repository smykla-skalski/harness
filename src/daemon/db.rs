use std::borrow::Cow;
use std::path::Path;

use rusqlite::Connection;

use crate::errors::{CliError, CliErrorKind};

/// `SQLite`-backed storage for the harness daemon. Replaces the file-based
/// discovery layer with indexed queries while keeping file writes for
/// backward compatibility with CLI offline access and agent runtimes.
pub struct DaemonDb {
    conn: Connection,
}

#[cfg(test)]
const SCHEMA_VERSION: &str = "1";

impl DaemonDb {
    /// Open (or create) the daemon database at the given path with WAL mode
    /// and performance-tuned PRAGMAs.
    ///
    /// # Errors
    /// Returns [`CliError`] on database open or PRAGMA failures.
    pub fn open(path: &Path) -> Result<Self, CliError> {
        let conn = Connection::open(path)
            .map_err(|error| db_error(format!("open daemon database: {error}")))?;
        apply_pragmas(&conn)?;
        let db = Self { conn };
        db.ensure_schema()?;
        Ok(db)
    }

    /// Open an in-memory database for testing.
    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self, CliError> {
        let conn = Connection::open_in_memory()
            .map_err(|error| db_error(format!("open in-memory database: {error}")))?;
        apply_pragmas(&conn)?;
        let db = Self { conn };
        db.ensure_schema()?;
        Ok(db)
    }

    /// Return the current schema version stored in `schema_meta`.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn schema_version(&self) -> Result<String, CliError> {
        self.conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .map_err(|error| db_error(format!("read schema version: {error}")))
    }

    /// Return the raw connection for advanced queries. Prefer typed methods
    /// on [`DaemonDb`] over direct connection access.
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    fn ensure_schema(&self) -> Result<(), CliError> {
        if !schema_exists(&self.conn)? {
            create_schema(&self.conn)?;
        }
        Ok(())
    }
}

fn schema_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check schema_meta existence: {error}")))
}

fn create_schema(conn: &Connection) -> Result<(), CliError> {
    emit_schema_init_info();
    conn.execute_batch(CREATE_SCHEMA)
        .map_err(|error| db_error(format!("create daemon database schema: {error}")))
}

/// Manual tracing event dispatch. The `info!` macro has inherent cognitive
/// complexity of 8 due to its internal expansion (tokio-rs/tracing#553),
/// which exceeds the pedantic threshold of 7.
fn emit_schema_init_info() {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "info",
        "harness::daemon::db",
        Level::INFO,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let message = "initializing daemon database schema";
    let values: &[Option<&dyn Value>] = &[Some(&message)];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}

fn apply_pragmas(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 5000;
         PRAGMA cache_size = -8000;",
    )
    .map_err(|error| db_error(format!("set database pragmas: {error}")))
}

fn db_error(detail: impl Into<Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

const CREATE_SCHEMA: &str = "
-- Schema version tracking
CREATE TABLE schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO schema_meta (key, value) VALUES ('version', '1');

-- Discovered projects
CREATE TABLE projects (
    project_id      TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    project_dir     TEXT,
    repository_root TEXT,
    checkout_id     TEXT NOT NULL,
    checkout_name   TEXT NOT NULL,
    context_root    TEXT NOT NULL UNIQUE,
    is_worktree     INTEGER NOT NULL DEFAULT 0,
    worktree_name   TEXT,
    origin_json     TEXT,
    discovered_at   TEXT NOT NULL,
    updated_at      TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX idx_projects_repository_root ON projects(repository_root);

-- Orchestration sessions
CREATE TABLE sessions (
    session_id              TEXT PRIMARY KEY,
    project_id              TEXT NOT NULL REFERENCES projects(project_id),
    schema_version          INTEGER NOT NULL,
    state_version           INTEGER NOT NULL DEFAULT 0,
    context                 TEXT NOT NULL,
    status                  TEXT NOT NULL,
    leader_id               TEXT,
    observe_id              TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    last_activity_at        TEXT,
    archived_at             TEXT,
    pending_leader_transfer TEXT,
    metrics_json            TEXT NOT NULL DEFAULT '{}',
    state_json              TEXT NOT NULL,
    is_active               INTEGER NOT NULL DEFAULT 1
) WITHOUT ROWID;

CREATE INDEX idx_sessions_project ON sessions(project_id);
CREATE INDEX idx_sessions_active ON sessions(is_active) WHERE is_active = 1;
CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);

-- Registered agents per session
CREATE TABLE agents (
    agent_id                  TEXT NOT NULL,
    session_id                TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    name                      TEXT NOT NULL,
    runtime                   TEXT NOT NULL,
    role                      TEXT NOT NULL,
    capabilities_json         TEXT NOT NULL DEFAULT '[]',
    status                    TEXT NOT NULL,
    agent_session_id          TEXT,
    joined_at                 TEXT NOT NULL,
    updated_at                TEXT NOT NULL,
    last_activity_at          TEXT,
    current_task_id           TEXT,
    runtime_capabilities_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (session_id, agent_id)
) WITHOUT ROWID;

CREATE INDEX idx_agents_runtime_session ON agents(runtime, agent_session_id);

-- Work items per session
CREATE TABLE tasks (
    task_id                 TEXT NOT NULL,
    session_id              TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    title                   TEXT NOT NULL,
    context                 TEXT,
    severity                TEXT NOT NULL,
    status                  TEXT NOT NULL,
    assigned_to             TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    created_by              TEXT,
    suggested_fix           TEXT,
    source                  TEXT NOT NULL DEFAULT 'manual',
    blocked_reason          TEXT,
    completed_at            TEXT,
    notes_json              TEXT NOT NULL DEFAULT '[]',
    checkpoint_summary_json TEXT,
    PRIMARY KEY (session_id, task_id)
) WITHOUT ROWID;

CREATE INDEX idx_tasks_session_status ON tasks(session_id, status);

-- Append-only session audit log
CREATE TABLE session_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    sequence        INTEGER NOT NULL,
    recorded_at     TEXT NOT NULL,
    transition_kind TEXT NOT NULL,
    transition_json TEXT NOT NULL,
    actor_id        TEXT,
    reason          TEXT,
    UNIQUE(session_id, sequence)
);

CREATE INDEX idx_session_log_session_time ON session_log(session_id, recorded_at);

-- Append-only task checkpoints
CREATE TABLE task_checkpoints (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    checkpoint_id TEXT NOT NULL UNIQUE,
    task_id       TEXT NOT NULL,
    session_id    TEXT NOT NULL,
    recorded_at   TEXT NOT NULL,
    actor_id      TEXT,
    summary       TEXT NOT NULL,
    progress      INTEGER NOT NULL,
    FOREIGN KEY (session_id, task_id) REFERENCES tasks(session_id, task_id) ON DELETE CASCADE
);

CREATE INDEX idx_checkpoints_task ON task_checkpoints(session_id, task_id);

-- Read-through index of signal files (files remain on disk)
CREATE TABLE signal_index (
    signal_id    TEXT PRIMARY KEY,
    session_id   TEXT NOT NULL,
    agent_id     TEXT NOT NULL,
    runtime      TEXT NOT NULL,
    command      TEXT NOT NULL,
    priority     TEXT NOT NULL,
    status       TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    source_agent TEXT NOT NULL,
    message      TEXT NOT NULL,
    action_hint  TEXT,
    signal_json  TEXT NOT NULL,
    ack_json     TEXT,
    file_path    TEXT NOT NULL,
    indexed_at   TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX idx_signals_session ON signal_index(session_id);
CREATE INDEX idx_signals_session_agent ON signal_index(session_id, agent_id);

-- Daemon audit events (replaces events.jsonl)
CREATE TABLE daemon_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TEXT NOT NULL,
    level       TEXT NOT NULL,
    message     TEXT NOT NULL
);

CREATE INDEX idx_daemon_events_time ON daemon_events(recorded_at DESC);

-- Change tracking for the watch loop
CREATE TABLE change_tracking (
    scope      TEXT PRIMARY KEY,
    version    INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO change_tracking (scope, version, updated_at)
VALUES ('global', 0, datetime('now'));
";

#[cfg(test)]
mod tests {
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
            "agents",
            "change_tracking",
            "daemon_events",
            "projects",
            "schema_meta",
            "session_log",
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
        let version: i64 = db
            .conn
            .query_row(
                "SELECT version FROM change_tracking WHERE scope = 'global'",
                [],
                |row| row.get(0),
            )
            .expect("global version");
        assert_eq!(version, 0);
    }
}
