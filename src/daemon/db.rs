use std::borrow::Cow;
use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::Connection;

use crate::workspace::utc_now;
use crate::daemon::index::DiscoveredProject;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{
    AgentRegistration, SessionLogEntry, SessionState, SessionStatus, TaskCheckpoint, WorkItem,
};

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

    // -- Sync methods for write-through persistence --

    /// Upsert a discovered project into the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_project(&self, project: &DiscoveredProject) -> Result<(), CliError> {
        let now = utc_now();
        self.conn
            .execute(
                "INSERT INTO projects (
                    project_id, name, project_dir, repository_root, checkout_id,
                    checkout_name, context_root, is_worktree, worktree_name,
                    origin_json, discovered_at, updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11)
                ON CONFLICT(project_id) DO UPDATE SET
                    name = excluded.name,
                    project_dir = excluded.project_dir,
                    repository_root = excluded.repository_root,
                    checkout_id = excluded.checkout_id,
                    checkout_name = excluded.checkout_name,
                    context_root = excluded.context_root,
                    is_worktree = excluded.is_worktree,
                    worktree_name = excluded.worktree_name,
                    origin_json = excluded.origin_json,
                    updated_at = excluded.updated_at",
                rusqlite::params![
                    project.project_id,
                    project.name,
                    project.project_dir.as_ref().map(|path| path.display().to_string()),
                    project.repository_root.as_ref().map(|path| path.display().to_string()),
                    project.checkout_id,
                    project.checkout_name,
                    project.context_root.display().to_string(),
                    project.is_worktree,
                    project.worktree_name,
                    Option::<String>::None,
                    now,
                ],
            )
            .map_err(|error| db_error(format!("sync project: {error}")))?;
        Ok(())
    }

    /// Upsert a session and replace its agents and tasks within a single
    /// transaction.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_session(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        let state_json = serde_json::to_string(state)
            .map_err(|error| db_error(format!("serialize session state: {error}")))?;
        let metrics_json = serde_json::to_string(&state.metrics)
            .map_err(|error| db_error(format!("serialize session metrics: {error}")))?;
        let pending_transfer_json = state
            .pending_leader_transfer
            .as_ref()
            .and_then(|transfer| serde_json::to_string(transfer).ok());
        let is_active = i32::from(state.status == SessionStatus::Active);

        let transaction = self.conn.unchecked_transaction()
            .map_err(|error| db_error(format!("begin session sync transaction: {error}")))?;

        transaction
            .execute(
                "INSERT INTO sessions (
                    session_id, project_id, schema_version, state_version, context,
                    status, leader_id, observe_id, created_at, updated_at,
                    last_activity_at, archived_at, pending_leader_transfer,
                    metrics_json, state_json, is_active
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                ON CONFLICT(session_id) DO UPDATE SET
                    schema_version = excluded.schema_version,
                    state_version = excluded.state_version,
                    context = excluded.context,
                    status = excluded.status,
                    leader_id = excluded.leader_id,
                    observe_id = excluded.observe_id,
                    updated_at = excluded.updated_at,
                    last_activity_at = excluded.last_activity_at,
                    archived_at = excluded.archived_at,
                    pending_leader_transfer = excluded.pending_leader_transfer,
                    metrics_json = excluded.metrics_json,
                    state_json = excluded.state_json,
                    is_active = excluded.is_active",
                rusqlite::params![
                    state.session_id,
                    project_id,
                    state.schema_version,
                    state.state_version,
                    state.context,
                    format!("{:?}", state.status).to_lowercase(),
                    state.leader_id,
                    state.observe_id,
                    state.created_at,
                    state.updated_at,
                    state.last_activity_at,
                    state.archived_at,
                    pending_transfer_json,
                    metrics_json,
                    state_json,
                    is_active,
                ],
            )
            .map_err(|error| db_error(format!("upsert session: {error}")))?;

        replace_agents(&transaction, &state.session_id, &state.agents)?;
        replace_tasks(&transaction, &state.session_id, &state.tasks)?;

        transaction
            .commit()
            .map_err(|error| db_error(format!("commit session sync: {error}")))?;
        Ok(())
    }

    /// Append a session log entry.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError> {
        let transition_json = serde_json::to_string(&entry.transition)
            .map_err(|error| db_error(format!("serialize log transition: {error}")))?;
        let transition_kind = extract_transition_kind(&transition_json);

        self.conn
            .execute(
                "INSERT OR IGNORE INTO session_log (
                    session_id, sequence, recorded_at, transition_kind,
                    transition_json, actor_id, reason
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![
                    entry.session_id,
                    entry.sequence,
                    entry.recorded_at,
                    transition_kind,
                    transition_json,
                    entry.actor_id,
                    entry.reason,
                ],
            )
            .map_err(|error| db_error(format!("append log entry: {error}")))?;
        Ok(())
    }

    /// Append a task checkpoint record.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn append_checkpoint(
        &self,
        session_id: &str,
        checkpoint: &TaskCheckpoint,
    ) -> Result<(), CliError> {
        self.conn
            .execute(
                "INSERT OR IGNORE INTO task_checkpoints (
                    checkpoint_id, task_id, session_id, recorded_at,
                    actor_id, summary, progress
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![
                    checkpoint.checkpoint_id,
                    checkpoint.task_id,
                    session_id,
                    checkpoint.recorded_at,
                    checkpoint.actor_id,
                    checkpoint.summary,
                    checkpoint.progress,
                ],
            )
            .map_err(|error| db_error(format!("append checkpoint: {error}")))?;
        Ok(())
    }

    /// Append a daemon audit event.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn append_daemon_event(&self, level: &str, message: &str) -> Result<(), CliError> {
        self.conn
            .execute(
                "INSERT INTO daemon_events (recorded_at, level, message)
                 VALUES (?1, ?2, ?3)",
                rusqlite::params![utc_now(), level, message],
            )
            .map_err(|error| db_error(format!("append daemon event: {error}")))?;
        Ok(())
    }

    /// Increment the version counter for a change-tracking scope.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn bump_change(&self, scope: &str) -> Result<(), CliError> {
        self.conn
            .execute(
                "INSERT INTO change_tracking (scope, version, updated_at)
                 VALUES (?1, 1, ?2)
                 ON CONFLICT(scope) DO UPDATE SET
                    version = version + 1,
                    updated_at = excluded.updated_at",
                rusqlite::params![scope, utc_now()],
            )
            .map_err(|error| db_error(format!("bump change: {error}")))?;
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

/// Extract the serde tag from a serialized `SessionTransition` JSON string.
/// Returns the variant name (e.g. `SessionStarted`, `AgentJoined`) for indexing.
fn extract_transition_kind(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            // Tagged enum serializes as {"VariantName": {...}} or "VariantName"
            value.as_object().and_then(|object| {
                object.keys().next().cloned()
            }).or_else(|| value.as_str().map(String::from))
        })
        .unwrap_or_default()
}

fn db_error(detail: impl Into<Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

fn replace_agents(
    transaction: &Connection,
    session_id: &str,
    agents: &BTreeMap<String, AgentRegistration>,
) -> Result<(), CliError> {
    transaction
        .execute("DELETE FROM agents WHERE session_id = ?1", [session_id])
        .map_err(|error| db_error(format!("delete agents: {error}")))?;

    let mut statement = transaction
        .prepare(
            "INSERT INTO agents (
                agent_id, session_id, name, runtime, role, capabilities_json,
                status, agent_session_id, joined_at, updated_at,
                last_activity_at, current_task_id, runtime_capabilities_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
        )
        .map_err(|error| db_error(format!("prepare agent insert: {error}")))?;

    for (agent_id, agent) in agents {
        let capabilities_json = serde_json::to_string(&agent.capabilities).unwrap_or_default();
        let runtime_capabilities_json =
            serde_json::to_string(&agent.runtime_capabilities).unwrap_or_default();

        statement
            .execute(rusqlite::params![
                agent_id,
                session_id,
                agent.name,
                agent.runtime,
                format!("{:?}", agent.role).to_lowercase(),
                capabilities_json,
                format!("{:?}", agent.status).to_lowercase(),
                agent.agent_session_id,
                agent.joined_at,
                agent.updated_at,
                agent.last_activity_at,
                agent.current_task_id,
                runtime_capabilities_json,
            ])
            .map_err(|error| db_error(format!("insert agent {agent_id}: {error}")))?;
    }
    Ok(())
}

fn replace_tasks(
    transaction: &Connection,
    session_id: &str,
    tasks: &BTreeMap<String, WorkItem>,
) -> Result<(), CliError> {
    transaction
        .execute("DELETE FROM tasks WHERE session_id = ?1", [session_id])
        .map_err(|error| db_error(format!("delete tasks: {error}")))?;

    let mut statement = transaction
        .prepare(
            "INSERT INTO tasks (
                task_id, session_id, title, context, severity, status,
                assigned_to, created_at, updated_at, created_by,
                suggested_fix, source, blocked_reason, completed_at,
                notes_json, checkpoint_summary_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
        )
        .map_err(|error| db_error(format!("prepare task insert: {error}")))?;

    for (task_id, task) in tasks {
        let notes_json = serde_json::to_string(&task.notes).unwrap_or_default();
        let checkpoint_summary_json = task
            .checkpoint_summary
            .as_ref()
            .and_then(|summary| serde_json::to_string(summary).ok());

        statement
            .execute(rusqlite::params![
                task_id,
                session_id,
                task.title,
                task.context,
                format!("{:?}", task.severity).to_lowercase(),
                format!("{:?}", task.status).to_lowercase(),
                task.assigned_to,
                task.created_at,
                task.updated_at,
                task.created_by,
                task.suggested_fix,
                format!("{:?}", task.source).to_lowercase(),
                task.blocked_reason,
                task.completed_at,
                notes_json,
                checkpoint_summary_json,
            ])
            .map_err(|error| db_error(format!("insert task {task_id}: {error}")))?;
    }
    Ok(())
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

    fn sample_project() -> DiscoveredProject {
        DiscoveredProject {
            project_id: "project-abc123".into(),
            name: "harness".into(),
            project_dir: Some("/tmp/harness".into()),
            repository_root: Some("/tmp/harness".into()),
            checkout_id: "checkout-abc123".into(),
            checkout_name: "Repository".into(),
            context_root: "/tmp/data/projects/project-abc123".into(),
            is_worktree: false,
            worktree_name: None,
        }
    }

    fn sample_session_state() -> SessionState {
        use crate::session::types::{
            AgentRegistration, AgentStatus, SessionRole, SessionMetrics,
            TaskSeverity, TaskSource, TaskStatus,
        };
        use crate::agents::runtime::RuntimeCapabilities;

        let mut agents = BTreeMap::new();
        agents.insert(
            "claude-leader".into(),
            AgentRegistration {
                agent_id: "claude-leader".into(),
                name: "Claude Leader".into(),
                runtime: "claude".into(),
                role: SessionRole::Leader,
                capabilities: vec!["general".into()],
                joined_at: "2026-04-03T12:00:00Z".into(),
                updated_at: "2026-04-03T12:05:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: Some("claude-session-1".into()),
                last_activity_at: Some("2026-04-03T12:05:00Z".into()),
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );

        let mut tasks = BTreeMap::new();
        tasks.insert(
            "task-1".into(),
            WorkItem {
                task_id: "task-1".into(),
                title: "Fix the bug".into(),
                context: Some("In module X".into()),
                severity: TaskSeverity::High,
                status: TaskStatus::Open,
                assigned_to: None,
                created_at: "2026-04-03T12:01:00Z".into(),
                updated_at: "2026-04-03T12:01:00Z".into(),
                created_by: Some("claude-leader".into()),
                notes: Vec::new(),
                suggested_fix: None,
                source: TaskSource::Manual,
                blocked_reason: None,
                completed_at: None,
                checkpoint_summary: None,
            },
        );

        SessionState {
            schema_version: 3,
            state_version: 1,
            session_id: "sess-test-1".into(),
            context: "test session".into(),
            status: SessionStatus::Active,
            created_at: "2026-04-03T12:00:00Z".into(),
            updated_at: "2026-04-03T12:05:00Z".into(),
            agents,
            tasks,
            leader_id: Some("claude-leader".into()),
            archived_at: None,
            last_activity_at: Some("2026-04-03T12:05:00Z".into()),
            observe_id: None,
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        }
    }

    #[test]
    fn sync_project_round_trip() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let name: String = db
            .conn
            .query_row(
                "SELECT name FROM projects WHERE project_id = ?1",
                [&project.project_id],
                |row| row.get(0),
            )
            .expect("query project");
        assert_eq!(name, "harness");
    }

    #[test]
    fn sync_project_upsert_updates() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let mut project = sample_project();
        db.sync_project(&project).expect("first sync");

        project.name = "renamed".into();
        db.sync_project(&project).expect("second sync");

        let name: String = db
            .conn
            .query_row(
                "SELECT name FROM projects WHERE project_id = ?1",
                [&project.project_id],
                |row| row.get(0),
            )
            .expect("query project");
        assert_eq!(name, "renamed");
    }

    #[test]
    fn sync_session_with_agents_and_tasks() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let context: String = db
            .conn
            .query_row(
                "SELECT context FROM sessions WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("query session");
        assert_eq!(context, "test session");

        let agent_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM agents WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("count agents");
        assert_eq!(agent_count, 1);

        let task_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM tasks WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("count tasks");
        assert_eq!(task_count, 1);
    }

    #[test]
    fn sync_session_replaces_agents_on_update() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let mut state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("first sync");

        state.agents.clear();
        state.state_version = 2;
        db.sync_session(&project.project_id, &state)
            .expect("second sync");

        let agent_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM agents WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("count agents");
        assert_eq!(agent_count, 0);
    }

    #[test]
    fn append_log_entry_inserts() {
        use crate::session::types::SessionTransition;

        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let entry = SessionLogEntry {
            sequence: 1,
            recorded_at: "2026-04-03T12:00:00Z".into(),
            session_id: state.session_id.clone(),
            transition: SessionTransition::SessionStarted {
                context: "test".into(),
            },
            actor_id: Some("claude-leader".into()),
            reason: None,
        };
        db.append_log_entry(&entry).expect("append log entry");

        let count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM session_log WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("count log entries");
        assert_eq!(count, 1);
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
    fn append_daemon_event_inserts() {
        let db = DaemonDb::open_in_memory().expect("open db");
        db.append_daemon_event("info", "test message")
            .expect("append event");

        let count: i64 = db
            .conn
            .query_row("SELECT COUNT(*) FROM daemon_events", [], |row| row.get(0))
            .expect("count events");
        assert_eq!(count, 1);
    }

    #[test]
    fn extract_transition_kind_parses_tagged_enum() {
        let json = r#"{"SessionStarted":{"context":"test"}}"#;
        assert_eq!(extract_transition_kind(json), "SessionStarted");
    }

    #[test]
    fn extract_transition_kind_parses_unit_variant() {
        let json = r#""SessionEnded""#;
        assert_eq!(extract_transition_kind(json), "SessionEnded");
    }
}
