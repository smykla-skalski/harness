use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use std::io::{Error as IoError, ErrorKind};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, types::Type};

use crate::agents::runtime::event::ConversationEvent;
use crate::agents::runtime::signal::Signal;
use crate::daemon::index::DiscoveredProject;
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{
    AgentRegistration, SessionLogEntry, SessionSignalRecord, SessionSignalStatus, SessionState,
    SessionStatus, TaskCheckpoint, WorkItem,
};
use crate::workspace::utc_now;

/// `SQLite`-backed storage for the harness daemon. Replaces the file-based
/// discovery layer with indexed queries while keeping file writes for
/// backward compatibility with CLI offline access and agent runtimes.
pub struct DaemonDb {
    conn: Connection,
}

impl fmt::Debug for DaemonDb {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DaemonDb").finish_non_exhaustive()
    }
}

const SCHEMA_VERSION: &str = "4";

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
            return Ok(());
        }
        self.run_migrations()
    }

    fn run_migrations(&self) -> Result<(), CliError> {
        let version = self.schema_version()?;
        let should_reclaim_space = match version.as_str() {
            "1" => {
                self.conn
                    .execute_batch(
                        "ALTER TABLE sessions ADD COLUMN title TEXT NOT NULL DEFAULT '';
                         UPDATE sessions SET title = context;
                         UPDATE sessions SET state_json = json_set(state_json, '$.title', context);
                         UPDATE schema_meta SET value = '2' WHERE key = 'version';",
                    )
                    .map_err(|error| db_error(format!("migrate v1 -> v2: {error}")))?;
                let reclaimed = migrate_v2_to_v3(&self.conn)?;
                migrate_v3_to_v4(&self.conn)?;
                reclaimed
            }
            "2" => {
                let reclaimed = migrate_v2_to_v3(&self.conn)?;
                migrate_v3_to_v4(&self.conn)?;
                reclaimed
            }
            "3" => {
                migrate_v3_to_v4(&self.conn)?;
                false
            }
            _ => false,
        };

        if should_reclaim_space {
            reclaim_unused_pages(&self.conn)?;
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
                    project
                        .project_dir
                        .as_ref()
                        .map(|path| path.display().to_string()),
                    project
                        .repository_root
                        .as_ref()
                        .map(|path| path.display().to_string()),
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
    pub fn sync_session(&self, project_id: &str, state: &SessionState) -> Result<(), CliError> {
        let state_json = serde_json::to_string(state)
            .map_err(|error| db_error(format!("serialize session state: {error}")))?;
        let metrics_json = serde_json::to_string(&state.metrics)
            .map_err(|error| db_error(format!("serialize session metrics: {error}")))?;
        let pending_transfer_json = state
            .pending_leader_transfer
            .as_ref()
            .and_then(|transfer| serde_json::to_string(transfer).ok());
        let is_active = i32::from(state.status == SessionStatus::Active);

        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin session sync transaction: {error}")))?;

        transaction
            .execute(
                "INSERT INTO sessions (
                    session_id, project_id, schema_version, state_version,
                    title, context,
                    status, leader_id, observe_id, created_at, updated_at,
                    last_activity_at, archived_at, pending_leader_transfer,
                    metrics_json, state_json, is_active
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
                ON CONFLICT(session_id) DO UPDATE SET
                    schema_version = excluded.schema_version,
                    state_version = excluded.state_version,
                    title = excluded.title,
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
                    state.title,
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

    // -- Import from existing file-based storage --

    /// Import all existing file-based project and session data into the
    /// database. Reuses the existing discovery code so all edge cases
    /// (migrations, worktrees, schema versioning) are handled.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or insert failures.
    pub fn import_from_files(&self) -> Result<ImportResult, CliError> {
        let projects = super::index::discover_projects()?;
        let sessions = super::index::discover_sessions_for(&projects, true)?;

        let mut result = ImportResult::default();

        for project in &projects {
            self.sync_project(project)?;
            result.projects += 1;
        }

        for resolved in &sessions {
            self.sync_session(&resolved.project.project_id, &resolved.state)?;
            result.sessions += 1;

            import_session_log(self, &resolved.project, &resolved.state.session_id)?;
            import_session_checkpoints(self, &resolved.project, &resolved.state)?;
            import_session_signals(self, resolved)?;
            import_session_activity(self, resolved)?;
            import_conversation_events(self, resolved)?;
        }

        import_daemon_events(self)?;
        self.bump_change("global")?;

        Ok(result)
    }

    /// Reconcile file-discovered sessions into the database, only
    /// importing sessions that are new or have a higher `state_version`
    /// than the DB copy. Daemon-first sessions (only in `SQLite`) are
    /// never touched.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    pub fn reconcile_sessions(
        &self,
        projects: &[super::index::DiscoveredProject],
        sessions: &[super::index::ResolvedSession],
    ) -> Result<ReconcileResult, CliError> {
        let mut result = ReconcileResult::default();

        for project in projects {
            self.sync_project(project)?;
            result.projects += 1;
        }

        for resolved in sessions {
            let db_version = self.session_state_version(&resolved.state.session_id)?;
            let file_version = i64::try_from(resolved.state.state_version).unwrap_or(i64::MAX);

            if db_version.is_some_and(|version| version >= file_version) {
                result.sessions_skipped += 1;
                continue;
            }

            self.sync_session(&resolved.project.project_id, &resolved.state)?;
            import_session_log(self, &resolved.project, &resolved.state.session_id)?;
            import_session_checkpoints(self, &resolved.project, &resolved.state)?;
            import_session_signals(self, resolved)?;
            import_session_activity(self, resolved)?;
            import_conversation_events(self, resolved)?;
            result.sessions_imported += 1;
        }

        if result.sessions_imported > 0 {
            self.bump_change("global")?;
        }

        Ok(result)
    }

    /// Discover projects and sessions from files, then reconcile into
    /// the database. Only imports sessions that are new or have a higher
    /// `state_version` than existing DB records. Safe to call while the
    /// daemon is serving - daemon-first sessions are never overwritten.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    pub fn reconcile_from_files(&self) -> Result<ReconcileResult, CliError> {
        let projects = super::index::discover_projects()?;
        let sessions = super::index::discover_sessions_for(&projects, true)?;
        self.reconcile_sessions(&projects, &sessions)
    }

    /// Return the number of rows in the sessions table.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn session_count(&self) -> Result<i64, CliError> {
        self.conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))
            .map_err(|error| db_error(format!("count sessions: {error}")))
    }

    /// Return the number of rows in the projects table.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn project_count(&self) -> Result<i64, CliError> {
        self.conn
            .query_row("SELECT COUNT(*) FROM projects", [], |row| row.get(0))
            .map_err(|error| db_error(format!("count projects: {error}")))
    }

    // -- Read query methods for API endpoints --

    /// Fast counts for the health endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn health_counts(&self) -> Result<(usize, usize, usize), CliError> {
        self.conn
            .query_row(
                "SELECT
                    (SELECT COUNT(DISTINCT project_id) FROM projects WHERE is_worktree = 0) AS project_count,
                    (SELECT COUNT(*) FROM projects WHERE is_worktree = 1) AS worktree_count,
                    (SELECT COUNT(*) FROM sessions) AS session_count",
                [],
                |row| {
                    Ok((
                        row.get::<_, usize>(0)?,
                        row.get::<_, usize>(1)?,
                        row.get::<_, usize>(2)?,
                    ))
                },
            )
            .map_err(|error| db_error(format!("health counts: {error}")))
    }

    /// Load all project summaries with session counts and worktree info.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn list_project_summaries(&self) -> Result<Vec<super::protocol::ProjectSummary>, CliError> {
        use super::protocol::{ProjectSummary, WorktreeSummary};

        let mut statement = self
            .conn
            .prepare(
                "SELECT
                    p.project_id, p.name, p.project_dir, p.context_root,
                    p.checkout_id, p.checkout_name, p.is_worktree, p.worktree_name,
                    COUNT(CASE WHEN s.is_active = 1 THEN 1 END) AS active_count,
                    COUNT(s.session_id) AS total_count
                 FROM projects p
                 LEFT JOIN sessions s ON s.project_id = p.project_id
                 GROUP BY p.project_id, p.checkout_id
                 ORDER BY p.name, p.checkout_name",
            )
            .map_err(|error| db_error(format!("prepare project summaries: {error}")))?;

        let rows = statement
            .query_map([], |row| {
                Ok(ProjectRow {
                    project_id: row.get(0)?,
                    name: row.get(1)?,
                    project_dir: row.get(2)?,
                    context_root: row.get(3)?,
                    checkout_id: row.get(4)?,
                    checkout_name: row.get(5)?,
                    is_worktree: row.get(6)?,
                    worktree_name: row.get(7)?,
                    active_session_count: row.get(8)?,
                    total_session_count: row.get(9)?,
                })
            })
            .map_err(|error| db_error(format!("query project summaries: {error}")))?;

        let all_rows: Vec<ProjectRow> = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read project row: {error}")))?;

        let mut grouped: BTreeMap<String, ProjectSummary> = BTreeMap::new();

        for row in all_rows {
            let entry = grouped
                .entry(row.project_id.clone())
                .or_insert_with(|| ProjectSummary {
                    project_id: row.project_id.clone(),
                    name: row.name.clone(),
                    project_dir: row.project_dir.clone(),
                    context_root: row.context_root.clone(),
                    active_session_count: 0,
                    total_session_count: 0,
                    worktrees: Vec::new(),
                });

            if row.is_worktree {
                entry.worktrees.push(WorktreeSummary {
                    checkout_id: row.checkout_id,
                    name: row.worktree_name.unwrap_or(row.checkout_name),
                    checkout_root: row.project_dir.unwrap_or_default(),
                    context_root: row.context_root,
                    active_session_count: row.active_session_count,
                    total_session_count: row.total_session_count,
                });
            }

            entry.active_session_count += row.active_session_count;
            entry.total_session_count += row.total_session_count;
        }

        let mut summaries: Vec<_> = grouped.into_values().collect();
        for summary in &mut summaries {
            summary.worktrees.sort_by(|a, b| a.name.cmp(&b.name));
        }
        Ok(summaries)
    }

    /// Load all session summaries for the sessions list endpoint.
    /// Joins session state with project data to produce protocol-level summaries.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn list_session_summaries_full(
        &self,
    ) -> Result<Vec<super::protocol::SessionSummary>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT
                    s.session_id, s.title, s.context, s.status, s.created_at, s.updated_at,
                    s.last_activity_at, s.leader_id, s.observe_id,
                    s.pending_leader_transfer, s.metrics_json,
                    p.project_id, p.name, p.project_dir, p.context_root,
                    p.checkout_id, p.is_worktree, p.worktree_name
                 FROM sessions s
                 JOIN projects p ON p.project_id = s.project_id
                 ORDER BY s.updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare session summaries: {error}")))?;

        let rows = statement
            .query_map([], |row| {
                Ok(SessionSummaryRow {
                    session_id: row.get(0)?,
                    title: row.get(1)?,
                    context: row.get(2)?,
                    status: row.get(3)?,
                    created_at: row.get(4)?,
                    updated_at: row.get(5)?,
                    last_activity_at: row.get(6)?,
                    leader_id: row.get(7)?,
                    observe_id: row.get(8)?,
                    pending_leader_transfer_json: row.get(9)?,
                    metrics_json: row.get(10)?,
                    project_id: row.get(11)?,
                    project_name: row.get(12)?,
                    project_dir: row.get(13)?,
                    context_root: row.get(14)?,
                    checkout_id: row.get(15)?,
                    is_worktree: row.get(16)?,
                    worktree_name: row.get(17)?,
                })
            })
            .map_err(|error| db_error(format!("query session summaries: {error}")))?;

        let mut summaries = Vec::new();
        for row in rows {
            let row = row.map_err(|error| db_error(format!("read session row: {error}")))?;
            summaries.push(row.into_summary());
        }
        Ok(summaries)
    }

    /// Load all session states for the sessions list endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn list_session_summaries(&self) -> Result<Vec<SessionState>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT s.state_json FROM sessions s
                 JOIN projects p ON p.project_id = s.project_id
                 ORDER BY s.updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare session list: {error}")))?;

        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| db_error(format!("query session list: {error}")))?;

        let mut sessions = Vec::new();
        for row in rows {
            let json = row.map_err(|error| db_error(format!("read session row: {error}")))?;
            let state: SessionState = serde_json::from_str(&json)
                .map_err(|error| db_error(format!("parse session state: {error}")))?;
            sessions.push(state);
        }
        Ok(sessions)
    }

    /// Resolve a session into a `ResolvedSession` using the DB instead of
    /// filesystem discovery.
    ///
    /// # Errors
    /// Returns [`CliError`] on query or parse failure.
    pub fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<super::index::ResolvedSession>, CliError> {
        let result = self.conn.query_row(
            "SELECT s.state_json, p.project_id, p.name, p.project_dir, p.repository_root,
                    p.checkout_id, p.checkout_name, p.context_root, p.is_worktree, p.worktree_name
             FROM sessions s
             JOIN projects p ON p.project_id = s.project_id
             WHERE s.session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, bool>(8)?,
                    row.get::<_, Option<String>>(9)?,
                ))
            },
        );

        match result {
            Ok((
                state_json,
                project_id,
                name,
                project_dir,
                repository_root,
                checkout_id,
                checkout_name,
                context_root,
                is_worktree,
                worktree_name,
            )) => {
                let state: SessionState = serde_json::from_str(&state_json)
                    .map_err(|error| db_error(format!("parse session state: {error}")))?;
                let project = DiscoveredProject {
                    project_id,
                    name,
                    project_dir: project_dir.map(PathBuf::from),
                    repository_root: repository_root.map(PathBuf::from),
                    checkout_id,
                    checkout_name,
                    context_root: PathBuf::from(context_root),
                    is_worktree,
                    worktree_name,
                };
                Ok(Some(super::index::ResolvedSession { project, state }))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("resolve session: {error}"))),
        }
    }

    /// Load a single session state by ID.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError> {
        let result = self.conn.query_row(
            "SELECT state_json FROM sessions WHERE session_id = ?1",
            [session_id],
            |row| row.get::<_, String>(0),
        );

        match result {
            Ok(json) => {
                let state: SessionState = serde_json::from_str(&json)
                    .map_err(|error| db_error(format!("parse session state: {error}")))?;
                Ok(Some(state))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("load session state: {error}"))),
        }
    }

    /// Load session log entries for a session, ordered by sequence.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_session_log(&self, session_id: &str) -> Result<Vec<SessionLogEntry>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT session_id, sequence, recorded_at, transition_json, actor_id, reason
                 FROM session_log WHERE session_id = ?1 ORDER BY sequence",
            )
            .map_err(|error| db_error(format!("prepare session log: {error}")))?;

        let rows = statement
            .query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, u64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })
            .map_err(|error| db_error(format!("query session log: {error}")))?;

        let mut entries = Vec::new();
        for row in rows {
            let (sid, sequence, recorded_at, transition_json, actor_id, reason) =
                row.map_err(|error| db_error(format!("read log row: {error}")))?;
            let transition = serde_json::from_str(&transition_json)
                .map_err(|error| db_error(format!("parse log transition: {error}")))?;
            entries.push(SessionLogEntry {
                sequence,
                recorded_at,
                session_id: sid,
                transition,
                actor_id,
                reason,
            });
        }
        Ok(entries)
    }

    /// Load task checkpoints for a session and task.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_task_checkpoints(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<Vec<TaskCheckpoint>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT checkpoint_id, task_id, recorded_at, actor_id, summary, progress
                 FROM task_checkpoints
                 WHERE session_id = ?1 AND task_id = ?2
                 ORDER BY recorded_at",
            )
            .map_err(|error| db_error(format!("prepare checkpoints: {error}")))?;

        let rows = statement
            .query_map(rusqlite::params![session_id, task_id], |row| {
                Ok(TaskCheckpoint {
                    checkpoint_id: row.get(0)?,
                    task_id: row.get(1)?,
                    recorded_at: row.get(2)?,
                    actor_id: row.get(3)?,
                    summary: row.get(4)?,
                    progress: row.get(5)?,
                })
            })
            .map_err(|error| db_error(format!("query checkpoints: {error}")))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read checkpoint row: {error}")))
    }

    /// Replace all signal index entries for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_signal_index(
        &self,
        session_id: &str,
        signals: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        self.conn
            .execute(
                "DELETE FROM signal_index WHERE session_id = ?1",
                [session_id],
            )
            .map_err(|error| db_error(format!("delete signals: {error}")))?;

        let mut statement = self
            .conn
            .prepare(
                "INSERT OR REPLACE INTO signal_index (
                    signal_id, session_id, agent_id, runtime, command, priority,
                    status, created_at, source_agent, message, action_hint,
                    signal_json, ack_json, file_path, indexed_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            )
            .map_err(|error| db_error(format!("prepare signal insert: {error}")))?;

        let now = utc_now();
        for record in signals {
            let signal_json = serde_json::to_string(&record.signal).unwrap_or_default();
            let ack_json = record
                .acknowledgment
                .as_ref()
                .and_then(|ack| serde_json::to_string(ack).ok());
            let status = format!("{:?}", record.status).to_lowercase();

            statement
                .execute(rusqlite::params![
                    record.signal.signal_id,
                    record.session_id,
                    record.agent_id,
                    record.runtime,
                    record.signal.command,
                    format!("{:?}", record.signal.priority).to_lowercase(),
                    status,
                    record.signal.created_at,
                    record.signal.source_agent,
                    record.signal.payload.message,
                    record.signal.payload.action_hint,
                    signal_json,
                    ack_json,
                    "",
                    now,
                ])
                .map_err(|error| db_error(format!("insert signal: {error}")))?;
        }
        Ok(())
    }

    /// Load signals for a session from the index.
    ///
    /// Pending signals whose `expires_at` has passed are surfaced as
    /// `Expired` at read time so every caller sees a correct status without
    /// a background sweeper or a schema change. Signals keep their stored
    /// status once an ack has been written, so acknowledged/rejected/deferred
    /// rows pass through unchanged.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT signal_json, ack_json, runtime, agent_id, session_id, status
                 FROM signal_index WHERE session_id = ?1
                 ORDER BY created_at DESC",
            )
            .map_err(|error| db_error(format!("prepare signal load: {error}")))?;

        let rows = statement
            .query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })
            .map_err(|error| db_error(format!("query signals: {error}")))?;

        let mut signals = Vec::new();
        for row in rows {
            let (signal_json, ack_json, runtime, agent_id, sid, status_str) =
                row.map_err(|error| db_error(format!("read signal row: {error}")))?;
            let signal: Signal = serde_json::from_str(&signal_json)
                .map_err(|error| db_error(format!("parse signal: {error}")))?;
            let acknowledgment = ack_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok());
            let stored = match status_str.as_str() {
                "pending" => SessionSignalStatus::Pending,
                "acknowledged" => SessionSignalStatus::Acknowledged,
                "rejected" => SessionSignalStatus::Rejected,
                "deferred" => SessionSignalStatus::Deferred,
                _ => SessionSignalStatus::Expired,
            };
            let status = derive_effective_signal_status(stored, &signal);
            signals.push(SessionSignalRecord {
                runtime,
                agent_id,
                session_id: sid,
                status,
                signal,
                acknowledgment,
            });
        }
        Ok(signals)
    }

    /// Whether any agent in the session shares a runtime session ID with a
    /// different orchestration session.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn session_has_shared_runtime_signal_dir(
        &self,
        state: &SessionState,
    ) -> Result<bool, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT COUNT(DISTINCT session_id)
                 FROM agents
                 WHERE runtime = ?1 AND agent_session_id = ?2",
            )
            .map_err(|error| db_error(format!("prepare shared runtime lookup: {error}")))?;

        for agent in state.agents.values() {
            let Some(agent_session_id) = agent.agent_session_id.as_deref() else {
                continue;
            };

            let count: i64 = statement
                .query_row(rusqlite::params![agent.runtime, agent_session_id], |row| {
                    row.get(0)
                })
                .map_err(|error| db_error(format!("query shared runtime lookup: {error}")))?;
            if count > 1 {
                return Ok(true);
            }
        }

        Ok(false)
    }

    /// Index conversation events for a session agent.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError> {
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin conversation event sync: {error}")))?;

        transaction
            .execute(
                "DELETE FROM conversation_events WHERE session_id = ?1 AND agent_id = ?2",
                rusqlite::params![session_id, agent_id],
            )
            .map_err(|error| db_error(format!("clear conversation events: {error}")))?;

        {
            let mut statement = transaction
                .prepare(
                    "INSERT INTO conversation_events
                        (session_id, agent_id, runtime, timestamp, sequence, kind, event_json)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                )
                .map_err(|error| db_error(format!("prepare event insert: {error}")))?;

            for event in events {
                let kind_json = serde_json::to_string(&event.kind).unwrap_or_default();
                let kind = extract_transition_kind(&kind_json);
                let json = serde_json::to_string(event).unwrap_or_default();
                statement
                    .execute(rusqlite::params![
                        session_id,
                        agent_id,
                        runtime,
                        event.timestamp,
                        event.sequence,
                        kind,
                        json,
                    ])
                    .map_err(|error| db_error(format!("insert conversation event: {error}")))?;
            }
        }

        transaction
            .commit()
            .map_err(|error| db_error(format!("commit conversation event sync: {error}")))?;
        Ok(())
    }

    /// Load conversation events for a session agent from the index.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<Vec<ConversationEvent>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT event_json FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2
                 ORDER BY sequence, id",
            )
            .map_err(|error| db_error(format!("prepare event load: {error}")))?;

        let rows = statement
            .query_map(rusqlite::params![session_id, agent_id], |row| {
                row.get::<_, String>(0)
            })
            .map_err(|error| db_error(format!("query events: {error}")))?;

        let mut events = Vec::new();
        for row in rows {
            let json = row.map_err(|error| db_error(format!("read event row: {error}")))?;
            if let Ok(event) = serde_json::from_str(&json) {
                events.push(event);
            }
        }
        Ok(events)
    }

    /// Cache agent activity summaries for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_agent_activity(
        &self,
        session_id: &str,
        activities: &[super::protocol::AgentToolActivitySummary],
    ) -> Result<(), CliError> {
        self.conn
            .execute(
                "DELETE FROM agent_activity_cache WHERE session_id = ?1",
                [session_id],
            )
            .map_err(|error| db_error(format!("delete activity cache: {error}")))?;

        let now = utc_now();
        let mut statement = self
            .conn
            .prepare(
                "INSERT INTO agent_activity_cache (agent_id, session_id, runtime, activity_json, cached_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .map_err(|error| db_error(format!("prepare activity insert: {error}")))?;

        for activity in activities {
            let json = serde_json::to_string(activity).unwrap_or_default();
            statement
                .execute(rusqlite::params![
                    activity.agent_id,
                    session_id,
                    activity.runtime,
                    json,
                    now,
                ])
                .map_err(|error| db_error(format!("insert activity: {error}")))?;
        }
        Ok(())
    }

    /// Load cached agent activity summaries for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<super::protocol::AgentToolActivitySummary>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT activity_json FROM agent_activity_cache
                 WHERE session_id = ?1 ORDER BY agent_id",
            )
            .map_err(|error| db_error(format!("prepare activity load: {error}")))?;

        let rows = statement
            .query_map([session_id], |row| row.get::<_, String>(0))
            .map_err(|error| db_error(format!("query activity: {error}")))?;

        let mut activities = Vec::new();
        for row in rows {
            let json = row.map_err(|error| db_error(format!("read activity row: {error}")))?;
            if let Ok(activity) = serde_json::from_str(&json) {
                activities.push(activity);
            }
        }
        Ok(activities)
    }

    /// Store a diagnostics cache entry.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn set_diagnostics_cache(&self, key: &str, value: &str) -> Result<(), CliError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO diagnostics_cache (key, value) VALUES (?1, ?2)",
                rusqlite::params![key, value],
            )
            .map_err(|error| db_error(format!("set diagnostics cache: {error}")))?;
        Ok(())
    }

    /// Load a diagnostics cache entry.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn get_diagnostics_cache(&self, key: &str) -> Result<Option<String>, CliError> {
        match self.conn.query_row(
            "SELECT value FROM diagnostics_cache WHERE key = ?1",
            [key],
            |row| row.get(0),
        ) {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("get diagnostics cache: {error}"))),
        }
    }

    /// Cache the launch agent status and workspace diagnostics at daemon startup.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn cache_startup_diagnostics(&self) -> Result<(), CliError> {
        let launch_agent = super::launchd::launch_agent_status();
        let launch_agent_json = serde_json::to_string(&launch_agent).unwrap_or_default();
        self.set_diagnostics_cache("launch_agent", &launch_agent_json)?;

        let workspace = super::state::diagnostics()?;
        let workspace_json = serde_json::to_string(&workspace).unwrap_or_default();
        self.set_diagnostics_cache("workspace", &workspace_json)?;

        Ok(())
    }

    /// Load cached launch agent status.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn load_cached_launch_agent_status(
        &self,
    ) -> Result<Option<super::launchd::LaunchAgentStatus>, CliError> {
        let json = self.get_diagnostics_cache("launch_agent")?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Load cached workspace diagnostics.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn load_cached_workspace_diagnostics(
        &self,
    ) -> Result<Option<super::state::DaemonDiagnostics>, CliError> {
        let json = self.get_diagnostics_cache("workspace")?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Load recent daemon events, ordered by most recent first.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_recent_daemon_events(
        &self,
        limit: usize,
    ) -> Result<Vec<super::state::DaemonAuditEvent>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT recorded_at, level, message FROM daemon_events
                 ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|error| db_error(format!("prepare daemon events: {error}")))?;

        let rows = statement
            .query_map([limit], |row| {
                Ok(super::state::DaemonAuditEvent {
                    recorded_at: row.get(0)?,
                    level: row.get(1)?,
                    message: row.get(2)?,
                })
            })
            .map_err(|error| db_error(format!("query daemon events: {error}")))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read event row: {error}")))
    }

    /// Re-sync a single session from file-based storage into `SQLite`.
    ///
    /// Resolves the session from files, upserts session/agents/tasks, and
    /// re-imports log entries, checkpoints, signals, activity, and
    /// conversation events. Bumps change tracking for the session and
    /// global scopes.
    ///
    /// # Errors
    /// Returns [`CliError`] on resolution, I/O, or SQL failures.
    pub fn resync_session(&self, session_id: &str) -> Result<(), CliError> {
        let resolved = super::index::resolve_session(session_id)?;
        self.sync_session(&resolved.project.project_id, &resolved.state)?;
        import_session_log(self, &resolved.project, &resolved.state.session_id)?;
        import_session_checkpoints(self, &resolved.project, &resolved.state)?;
        import_session_signals(self, &resolved)?;
        import_session_activity(self, &resolved)?;
        import_conversation_events(self, &resolved)?;
        self.bump_change(&resolved.state.session_id)?;
        self.bump_change("global")?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Daemon-first direct mutation helpers
    // -----------------------------------------------------------------------

    /// Load a session's state for in-memory mutation. Returns `None`
    /// when the session does not exist.
    ///
    /// This is the read side of the daemon-first mutation pattern:
    /// load state, apply business logic, save back via
    /// [`save_session_state`].
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or deserialization failures.
    pub fn load_session_state_for_mutation(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionState>, CliError> {
        self.load_session_state(session_id)
    }

    /// Persist a mutated session state back to `SQLite`. This is the
    /// write side of the daemon-first mutation pattern after
    /// [`load_session_state_for_mutation`] and an `apply_*` call.
    ///
    /// Delegates to [`sync_session`] which performs a full upsert of
    /// the session row plus denormalized agents and tasks.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn save_session_state(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        self.sync_session(project_id, state)
    }

    /// Insert a new session record with `is_active = 1`. Use this for
    /// the daemon-first `start_session` path where the session is
    /// created directly in `SQLite` without touching files.
    ///
    /// Delegates to [`sync_session`] (which is an upsert) and then
    /// explicitly ensures the active flag is set.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn create_session_record(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        self.sync_session(project_id, state)?;
        // sync_session sets is_active based on status, but be explicit
        // for clarity: a newly created session is always active.
        self.conn
            .execute(
                "UPDATE sessions SET is_active = 1 WHERE session_id = ?1",
                [&state.session_id],
            )
            .map_err(|error| db_error(format!("mark new session active: {error}")))?;
        Ok(())
    }

    /// Clear the active flag for a session (replaces file-based
    /// `storage::deregister_active`).
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn mark_session_inactive(&self, session_id: &str) -> Result<(), CliError> {
        self.conn
            .execute(
                "UPDATE sessions SET is_active = 0 WHERE session_id = ?1",
                [session_id],
            )
            .map_err(|error| db_error(format!("mark session inactive: {error}")))?;
        Ok(())
    }

    /// Return the `state_version` for a session, or `None` if the session
    /// does not exist in the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn session_state_version(&self, session_id: &str) -> Result<Option<i64>, CliError> {
        let result = self.conn.query_row(
            "SELECT state_version FROM sessions WHERE session_id = ?1",
            [session_id],
            |row| row.get::<_, i64>(0),
        );
        match result {
            Ok(version) => Ok(Some(version)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("session_state_version: {error}"))),
        }
    }

    /// Look up the project that owns a session.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn project_id_for_session(&self, session_id: &str) -> Result<Option<String>, CliError> {
        let result = self.conn.query_row(
            "SELECT project_id FROM sessions WHERE session_id = ?1",
            [session_id],
            |row| row.get::<_, String>(0),
        );
        match result {
            Ok(project_id) => Ok(Some(project_id)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("project_id_for_session: {error}"))),
        }
    }

    /// Look up the project directory for a session by joining sessions
    /// and projects.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn project_dir_for_session(&self, session_id: &str) -> Result<Option<String>, CliError> {
        let result = self.conn.query_row(
            "SELECT p.project_dir FROM sessions s
             JOIN projects p ON s.project_id = p.project_id
             WHERE s.session_id = ?1",
            [session_id],
            |row| row.get::<_, Option<String>>(0),
        );
        match result {
            Ok(project_dir) => Ok(project_dir),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("project_dir_for_session: {error}"))),
        }
    }

    /// Find the project ID for a given directory path. Matches against
    /// `project_dir` first, then `context_root`.
    ///
    /// # Errors
    /// Returns [`CliError`] if the project is not found or on SQL failures.
    pub fn ensure_project_for_dir(&self, project_dir: &str) -> Result<String, CliError> {
        let result = self.conn.query_row(
            "SELECT project_id FROM projects
             WHERE project_dir = ?1 OR context_root = ?1
             LIMIT 1",
            [project_dir],
            |row| row.get::<_, String>(0),
        );
        match result {
            Ok(project_id) => Ok(project_id),
            Err(rusqlite::Error::QueryReturnedNoRows) => Err(db_error(format!(
                "no project found for directory '{project_dir}'"
            ))),
            Err(error) => Err(db_error(format!("ensure_project_for_dir: {error}"))),
        }
    }

    /// Persist a Codex controller run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on serialization or SQL failures.
    pub fn save_codex_run(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        let pending_approvals_json = serde_json::to_string(&snapshot.pending_approvals)
            .map_err(|error| db_error(format!("serialize codex approvals: {error}")))?;
        self.conn
            .execute(
                "INSERT INTO codex_runs (
                    run_id, session_id, project_dir, thread_id, turn_id, mode,
                    status, prompt, latest_summary, final_message, error,
                    pending_approvals_json, created_at, updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                ON CONFLICT(run_id) DO UPDATE SET
                    session_id = excluded.session_id,
                    project_dir = excluded.project_dir,
                    thread_id = excluded.thread_id,
                    turn_id = excluded.turn_id,
                    mode = excluded.mode,
                    status = excluded.status,
                    prompt = excluded.prompt,
                    latest_summary = excluded.latest_summary,
                    final_message = excluded.final_message,
                    error = excluded.error,
                    pending_approvals_json = excluded.pending_approvals_json,
                    updated_at = excluded.updated_at",
                rusqlite::params![
                    snapshot.run_id,
                    snapshot.session_id,
                    snapshot.project_dir,
                    snapshot.thread_id,
                    snapshot.turn_id,
                    codex_mode_as_str(snapshot.mode),
                    codex_status_as_str(snapshot.status),
                    snapshot.prompt,
                    snapshot.latest_summary,
                    snapshot.final_message,
                    snapshot.error,
                    pending_approvals_json,
                    snapshot.created_at,
                    snapshot.updated_at,
                ],
            )
            .map_err(|error| db_error(format!("save codex run: {error}")))?;
        Ok(())
    }

    /// Load one Codex controller run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub fn codex_run(&self, run_id: &str) -> Result<Option<CodexRunSnapshot>, CliError> {
        let result = self.conn.query_row(
            "SELECT run_id, session_id, project_dir, thread_id, turn_id, mode,
                status, prompt, latest_summary, final_message, error,
                pending_approvals_json, created_at, updated_at
             FROM codex_runs
             WHERE run_id = ?1",
            [run_id],
            codex_run_from_row,
        );
        match result {
            Ok(snapshot) => Ok(Some(snapshot)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("load codex run: {error}"))),
        }
    }

    /// List Codex controller runs for a session, newest first.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub fn list_codex_runs(&self, session_id: &str) -> Result<Vec<CodexRunSnapshot>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT run_id, session_id, project_dir, thread_id, turn_id, mode,
                    status, prompt, latest_summary, final_message, error,
                    pending_approvals_json, created_at, updated_at
                 FROM codex_runs
                 WHERE session_id = ?1
                 ORDER BY updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare codex run list: {error}")))?;
        let rows = statement
            .query_map([session_id], codex_run_from_row)
            .map_err(|error| db_error(format!("query codex run list: {error}")))?;

        let mut snapshots = Vec::new();
        for row in rows {
            snapshots.push(row.map_err(|error| db_error(format!("read codex run row: {error}")))?);
        }
        Ok(snapshots)
    }
}

fn codex_run_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CodexRunSnapshot> {
    let mode_raw: String = row.get(5)?;
    let status_raw: String = row.get(6)?;
    let pending_approvals_json: String = row.get(11)?;
    Ok(CodexRunSnapshot {
        run_id: row.get(0)?,
        session_id: row.get(1)?,
        project_dir: row.get(2)?,
        thread_id: row.get(3)?,
        turn_id: row.get(4)?,
        mode: codex_mode_from_str(&mode_raw).map_err(parse_error_to_sql)?,
        status: codex_status_from_str(&status_raw).map_err(parse_error_to_sql)?,
        prompt: row.get(7)?,
        latest_summary: row.get(8)?,
        final_message: row.get(9)?,
        error: row.get(10)?,
        pending_approvals: serde_json::from_str(&pending_approvals_json)
            .map_err(|error| parse_error_to_sql(format!("parse codex approvals: {error}")))?,
        created_at: row.get(12)?,
        updated_at: row.get(13)?,
    })
}

fn parse_error_to_sql(error: String) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        0,
        Type::Text,
        Box::new(IoError::new(ErrorKind::InvalidData, error)),
    )
}

fn codex_mode_as_str(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report => "report",
        CodexRunMode::WorkspaceWrite => "workspace_write",
        CodexRunMode::Approval => "approval",
    }
}

fn codex_mode_from_str(value: &str) -> Result<CodexRunMode, String> {
    match value {
        "report" => Ok(CodexRunMode::Report),
        "workspace_write" => Ok(CodexRunMode::WorkspaceWrite),
        "approval" => Ok(CodexRunMode::Approval),
        _ => Err(format!("unknown codex run mode '{value}'")),
    }
}

fn codex_status_as_str(status: CodexRunStatus) -> &'static str {
    match status {
        CodexRunStatus::Queued => "queued",
        CodexRunStatus::Running => "running",
        CodexRunStatus::WaitingApproval => "waiting_approval",
        CodexRunStatus::Completed => "completed",
        CodexRunStatus::Failed => "failed",
        CodexRunStatus::Cancelled => "cancelled",
    }
}

fn codex_status_from_str(value: &str) -> Result<CodexRunStatus, String> {
    match value {
        "queued" => Ok(CodexRunStatus::Queued),
        "running" => Ok(CodexRunStatus::Running),
        "waiting_approval" => Ok(CodexRunStatus::WaitingApproval),
        "completed" => Ok(CodexRunStatus::Completed),
        "failed" => Ok(CodexRunStatus::Failed),
        "cancelled" => Ok(CodexRunStatus::Cancelled),
        _ => Err(format!("unknown codex run status '{value}'")),
    }
}

/// Summary of what was imported from file-based storage.
#[derive(Debug, Default)]
pub struct ImportResult {
    pub projects: usize,
    pub sessions: usize,
}

/// Summary of background file reconciliation.
#[derive(Debug, Default)]
pub struct ReconcileResult {
    pub projects: usize,
    pub sessions_imported: usize,
    pub sessions_skipped: usize,
}

fn import_session_log(
    db: &DaemonDb,
    project: &DiscoveredProject,
    session_id: &str,
) -> Result<(), CliError> {
    let entries = super::index::load_log_entries(project, session_id)?;
    for entry in &entries {
        db.append_log_entry(entry)?;
    }
    Ok(())
}

fn import_session_checkpoints(
    db: &DaemonDb,
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<(), CliError> {
    for task_id in state.tasks.keys() {
        let checkpoints = super::index::load_task_checkpoints(project, &state.session_id, task_id)?;
        for checkpoint in &checkpoints {
            db.append_checkpoint(&state.session_id, checkpoint)?;
        }
    }
    Ok(())
}

fn import_session_signals(
    db: &DaemonDb,
    resolved: &super::index::ResolvedSession,
) -> Result<(), CliError> {
    let signals = super::snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(&resolved.state.session_id, &signals)
}

fn import_session_activity(
    db: &DaemonDb,
    resolved: &super::index::ResolvedSession,
) -> Result<(), CliError> {
    let activities = super::snapshot::load_agent_activity_for(&resolved.project, &resolved.state)?;
    db.sync_agent_activity(&resolved.state.session_id, &activities)
}

fn import_conversation_events(
    db: &DaemonDb,
    resolved: &super::index::ResolvedSession,
) -> Result<(), CliError> {
    clear_session_conversation_events(&db.conn, &resolved.state.session_id)?;
    for (agent_id, agent) in &resolved.state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&resolved.state.session_id);
        let events = super::index::load_conversation_events(
            &resolved.project,
            &agent.runtime,
            session_key,
            agent_id,
        )?;
        db.sync_conversation_events(
            &resolved.state.session_id,
            agent_id,
            &agent.runtime,
            &events,
        )?;
    }
    Ok(())
}

fn clear_session_conversation_events(conn: &Connection, session_id: &str) -> Result<(), CliError> {
    conn.execute(
        "DELETE FROM conversation_events WHERE session_id = ?1",
        [session_id],
    )
    .map_err(|error| db_error(format!("clear session conversation events: {error}")))?;
    Ok(())
}

fn import_daemon_events(db: &DaemonDb) -> Result<(), CliError> {
    let events = super::state::read_recent_events(1000)?;
    for event in &events {
        db.conn
            .execute(
                "INSERT OR IGNORE INTO daemon_events (recorded_at, level, message)
                 VALUES (?1, ?2, ?3)",
                rusqlite::params![event.recorded_at, event.level, event.message],
            )
            .map_err(|error| db_error(format!("import daemon event: {error}")))?;
    }
    Ok(())
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

fn migrate_v2_to_v3(conn: &Connection) -> Result<bool, CliError> {
    let transaction = conn
        .unchecked_transaction()
        .map_err(|error| db_error(format!("begin v2 -> v3 migration: {error}")))?;

    let removed_conversation_duplicates = transaction
        .execute(
            "DELETE FROM conversation_events
             WHERE id NOT IN (
                 SELECT MIN(id)
                 FROM conversation_events
                 GROUP BY session_id, agent_id, sequence
             )",
            [],
        )
        .map_err(|error| db_error(format!("dedupe conversation events: {error}")))?;
    transaction
        .execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_conv_events_identity
             ON conversation_events(session_id, agent_id, sequence)",
            [],
        )
        .map_err(|error| db_error(format!("create conversation event identity index: {error}")))?;

    let removed_daemon_duplicates = transaction
        .execute(
            "DELETE FROM daemon_events
             WHERE id NOT IN (
                 SELECT MIN(id)
                 FROM daemon_events
                 GROUP BY recorded_at, level, message
             )",
            [],
        )
        .map_err(|error| db_error(format!("dedupe daemon events: {error}")))?;
    transaction
        .execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_daemon_events_identity
             ON daemon_events(recorded_at, level, message)",
            [],
        )
        .map_err(|error| db_error(format!("create daemon event identity index: {error}")))?;

    transaction
        .execute(
            "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
            ["3"],
        )
        .map_err(|error| db_error(format!("bump schema version to v3: {error}")))?;

    transaction
        .commit()
        .map_err(|error| db_error(format!("commit v2 -> v3 migration: {error}")))?;

    Ok(removed_conversation_duplicates > 0 || removed_daemon_duplicates > 0)
}

fn migrate_v3_to_v4(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(CODEX_RUNS_SCHEMA)
        .map_err(|error| db_error(format!("migrate v3 -> v4 codex runs: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
        [SCHEMA_VERSION],
    )
    .map_err(|error| db_error(format!("bump schema version to v4: {error}")))?;
    Ok(())
}

fn reclaim_unused_pages(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        .map_err(|error| db_error(format!("reclaim unused database pages: {error}")))
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

struct ProjectRow {
    project_id: String,
    name: String,
    project_dir: Option<String>,
    context_root: String,
    checkout_id: String,
    checkout_name: String,
    is_worktree: bool,
    worktree_name: Option<String>,
    active_session_count: usize,
    total_session_count: usize,
}

struct SessionSummaryRow {
    session_id: String,
    title: String,
    context: String,
    status: String,
    created_at: String,
    updated_at: String,
    last_activity_at: Option<String>,
    leader_id: Option<String>,
    observe_id: Option<String>,
    pending_leader_transfer_json: Option<String>,
    metrics_json: String,
    project_id: String,
    project_name: String,
    project_dir: Option<String>,
    context_root: String,
    checkout_id: String,
    is_worktree: bool,
    worktree_name: Option<String>,
}

impl SessionSummaryRow {
    fn into_summary(self) -> super::protocol::SessionSummary {
        use super::protocol::SessionSummary;

        let status = match self.status.as_str() {
            "active" => SessionStatus::Active,
            "paused" => SessionStatus::Paused,
            _ => SessionStatus::Ended,
        };
        let pending_leader_transfer = self
            .pending_leader_transfer_json
            .and_then(|json| serde_json::from_str(&json).ok());
        let metrics = serde_json::from_str(&self.metrics_json).unwrap_or_default();
        let checkout_root = self.project_dir.clone().unwrap_or_default();

        SessionSummary {
            project_id: self.project_id,
            project_name: self.project_name,
            project_dir: self.project_dir,
            context_root: self.context_root,
            checkout_id: self.checkout_id,
            checkout_root,
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name,
            session_id: self.session_id,
            title: self.title,
            context: self.context,
            status,
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_activity_at: self.last_activity_at,
            leader_id: self.leader_id,
            observe_id: self.observe_id,
            pending_leader_transfer,
            metrics,
        }
    }
}

/// Extract the serde tag from a serialized `SessionTransition` JSON string.
/// Returns the variant name (e.g. `SessionStarted`, `AgentJoined`) for indexing.
fn extract_transition_kind(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            // Tagged enum serializes as {"VariantName": {...}} or "VariantName"
            value
                .as_object()
                .and_then(|object| object.keys().next().cloned())
                .or_else(|| value.as_str().map(String::from))
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

const CODEX_RUNS_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS codex_runs (
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

CREATE INDEX IF NOT EXISTS idx_codex_runs_session_updated
    ON codex_runs(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_codex_runs_status
    ON codex_runs(status);
";

const CREATE_SCHEMA: &str = "
-- Schema version tracking
CREATE TABLE schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO schema_meta (key, value) VALUES ('version', '4');

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
    title                   TEXT NOT NULL DEFAULT '',
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
CREATE UNIQUE INDEX idx_daemon_events_identity
    ON daemon_events(recorded_at, level, message);

-- Indexed conversation events from agent transcripts
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

CREATE INDEX idx_conv_events_session ON conversation_events(session_id);
CREATE INDEX idx_conv_events_agent ON conversation_events(session_id, agent_id);
CREATE UNIQUE INDEX idx_conv_events_identity
    ON conversation_events(session_id, agent_id, sequence);

-- Cached agent activity summaries (computed from transcript files)
CREATE TABLE agent_activity_cache (
    agent_id     TEXT NOT NULL,
    session_id   TEXT NOT NULL,
    runtime      TEXT NOT NULL,
    activity_json TEXT NOT NULL,
    cached_at    TEXT NOT NULL,
    PRIMARY KEY (session_id, agent_id)
) WITHOUT ROWID;

-- Change tracking for the watch loop
CREATE TABLE change_tracking (
    scope      TEXT PRIMARY KEY,
    version    INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
) WITHOUT ROWID;

-- Cached diagnostics metadata (avoids process spawns and directory walks)
CREATE TABLE diagnostics_cache (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

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

INSERT INTO change_tracking (scope, version, updated_at)
VALUES ('global', 0, datetime('now'));
";

fn derive_effective_signal_status(
    stored: SessionSignalStatus,
    signal: &Signal,
) -> SessionSignalStatus {
    if stored != SessionSignalStatus::Pending {
        return stored;
    }
    match chrono::DateTime::parse_from_rfc3339(&signal.expires_at) {
        Ok(expires_at) if expires_at < chrono::Utc::now() => SessionSignalStatus::Expired,
        _ => stored,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::runtime::event::ConversationEventKind;
    use std::time::{Duration, Instant};

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
            "agent_activity_cache",
            "agents",
            "change_tracking",
            "codex_runs",
            "conversation_events",
            "daemon_events",
            "diagnostics_cache",
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
    fn codex_runs_round_trip_and_list_newest_first() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let mut older = sample_codex_run("codex-run-1", "2026-04-09T10:00:00Z");
        older.status = CodexRunStatus::Completed;
        older.final_message = Some("Done.".into());
        db.save_codex_run(&older).expect("save older run");

        let newer = sample_codex_run("codex-run-2", "2026-04-09T11:00:00Z");
        db.save_codex_run(&newer).expect("save newer run");

        let runs = db
            .list_codex_runs(&state.session_id)
            .expect("list codex runs");
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].run_id, "codex-run-2");
        assert_eq!(runs[1].run_id, "codex-run-1");

        let loaded = db
            .codex_run("codex-run-1")
            .expect("load codex run")
            .expect("present");
        assert_eq!(loaded.status, CodexRunStatus::Completed);
        assert_eq!(loaded.final_message.as_deref(), Some("Done."));
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

    fn sample_signal_record(expires_at: &str) -> SessionSignalRecord {
        use crate::agents::runtime::signal::{DeliveryConfig, SignalPayload, SignalPriority};
        use serde_json::json;

        SessionSignalRecord {
            runtime: "claude".into(),
            agent_id: "claude-leader".into(),
            session_id: "sess-test-1".into(),
            status: SessionSignalStatus::Pending,
            signal: Signal {
                signal_id: "sig-test-1".into(),
                version: 1,
                created_at: "2026-04-03T12:00:00Z".into(),
                expires_at: expires_at.into(),
                source_agent: "claude".into(),
                command: "inject_context".into(),
                priority: SignalPriority::Normal,
                payload: SignalPayload {
                    message: "test".into(),
                    action_hint: None,
                    related_files: vec![],
                    metadata: json!({}),
                },
                delivery: DeliveryConfig {
                    max_retries: 3,
                    retry_count: 0,
                    idempotency_key: None,
                },
            },
            acknowledgment: None,
        }
    }

    #[test]
    fn derive_effective_signal_status_past_expiry_flips_pending_to_expired() {
        let signal = sample_signal_record("2020-01-01T00:00:00Z");
        let status = derive_effective_signal_status(SessionSignalStatus::Pending, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Expired);
    }

    #[test]
    fn derive_effective_signal_status_future_expiry_stays_pending() {
        let signal = sample_signal_record("2099-12-31T23:59:59Z");
        let status = derive_effective_signal_status(SessionSignalStatus::Pending, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Pending);
    }

    #[test]
    fn derive_effective_signal_status_acknowledged_passes_through() {
        let signal = sample_signal_record("2020-01-01T00:00:00Z");
        let status =
            derive_effective_signal_status(SessionSignalStatus::Acknowledged, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Acknowledged);
    }

    #[test]
    fn derive_effective_signal_status_unparseable_expiry_stays_pending() {
        let signal = sample_signal_record("not-a-timestamp");
        let status = derive_effective_signal_status(SessionSignalStatus::Pending, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Pending);
    }

    #[test]
    fn load_signals_reports_expired_for_past_pending() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let record = sample_signal_record("2020-01-01T00:00:00Z");
        db.sync_signal_index(&state.session_id, std::slice::from_ref(&record))
            .expect("sync signals");

        let loaded = db.load_signals(&state.session_id).expect("load signals");
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].status, SessionSignalStatus::Expired);
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
        use crate::agents::runtime::RuntimeCapabilities;
        use crate::session::types::{
            AgentRegistration, AgentStatus, SessionMetrics, SessionRole, TaskQueuePolicy,
            TaskSeverity, TaskSource, TaskStatus,
        };

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
                queue_policy: TaskQueuePolicy::Locked,
                queued_at: None,
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
            title: "test title".into(),
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

    fn sample_codex_run(run_id: &str, updated_at: &str) -> CodexRunSnapshot {
        CodexRunSnapshot {
            run_id: run_id.into(),
            session_id: "sess-test-1".into(),
            project_dir: "/tmp/harness".into(),
            thread_id: Some("thread-1".into()),
            turn_id: Some("turn-1".into()),
            mode: CodexRunMode::Approval,
            status: CodexRunStatus::Running,
            prompt: "Investigate the suite.".into(),
            latest_summary: Some("Working".into()),
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            created_at: "2026-04-09T09:00:00Z".into(),
            updated_at: updated_at.into(),
        }
    }

    fn performance_project(index: usize) -> DiscoveredProject {
        DiscoveredProject {
            project_id: format!("project-{index}"),
            name: format!("harness-{index}"),
            project_dir: Some(format!("/tmp/harness-{index}").into()),
            repository_root: Some(format!("/tmp/harness-{index}").into()),
            checkout_id: format!("checkout-{index}"),
            checkout_name: "Repository".into(),
            context_root: format!("/tmp/data/projects/project-{index}").into(),
            is_worktree: false,
            worktree_name: None,
        }
    }

    fn sample_conversation_event(sequence: u64, content: &str) -> ConversationEvent {
        ConversationEvent {
            timestamp: Some(format!("2026-04-03T12:00:{sequence:02}Z")),
            sequence,
            kind: ConversationEventKind::AssistantText {
                content: content.to_string(),
            },
            agent: "claude-leader".into(),
            session_id: "sess-test-1".into(),
        }
    }

    fn performance_session_state(project_index: usize, session_index: usize) -> SessionState {
        use crate::agents::runtime::RuntimeCapabilities;
        use crate::session::types::{
            AgentRegistration, AgentStatus, SessionMetrics, SessionRole, TaskQueuePolicy,
            TaskSeverity, TaskSource, TaskStatus,
        };

        let token = project_index * 100 + session_index;
        let session_id = format!("sess-{project_index}-{session_index}");
        let leader_id = format!("leader-{project_index}-{session_index}");
        let task_id = format!("task-{project_index}-{session_index}");
        let timestamp = format!(
            "2026-04-{day:02}T12:{minute:02}:{second:02}Z",
            day = 1 + (token % 27),
            minute = (token * 3) % 60,
            second = (token * 7) % 60,
        );

        let mut agents = BTreeMap::new();
        agents.insert(
            leader_id.clone(),
            AgentRegistration {
                agent_id: leader_id.clone(),
                name: format!("Leader {session_id}"),
                runtime: "claude".into(),
                role: SessionRole::Leader,
                capabilities: vec!["general".into()],
                joined_at: timestamp.clone(),
                updated_at: timestamp.clone(),
                status: AgentStatus::Active,
                agent_session_id: Some(format!("{leader_id}-session")),
                last_activity_at: Some(timestamp.clone()),
                current_task_id: Some(task_id.clone()),
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );

        let mut tasks = BTreeMap::new();
        tasks.insert(
            task_id.clone(),
            WorkItem {
                task_id,
                title: format!("Performance task {session_id}"),
                context: Some(format!("Regression guard {project_index}-{session_index}")),
                severity: TaskSeverity::Medium,
                status: if token % 5 == 0 {
                    TaskStatus::Done
                } else {
                    TaskStatus::Open
                },
                assigned_to: Some(leader_id.clone()),
                queue_policy: TaskQueuePolicy::Locked,
                queued_at: None,
                created_at: timestamp.clone(),
                updated_at: timestamp.clone(),
                created_by: Some(leader_id.clone()),
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
            session_id: session_id.clone(),
            title: format!("perf {project_index}-{session_index}"),
            context: format!("performance lane {project_index}-{session_index}"),
            status: if token % 6 == 0 {
                SessionStatus::Ended
            } else {
                SessionStatus::Active
            },
            created_at: timestamp.clone(),
            updated_at: timestamp.clone(),
            agents,
            tasks,
            leader_id: Some(leader_id),
            archived_at: None,
            last_activity_at: Some(timestamp),
            observe_id: None,
            pending_leader_transfer: None,
            metrics: SessionMetrics {
                agent_count: 1,
                active_agent_count: 1,
                open_task_count: 1,
                in_progress_task_count: (token % 3) as u32,
                blocked_task_count: (token % 2) as u32,
                completed_task_count: (token % 4) as u32,
            },
        }
    }

    fn seeded_performance_db(project_count: usize, sessions_per_project: usize) -> DaemonDb {
        let db = DaemonDb::open_in_memory().expect("open db");

        for project_index in 0..project_count {
            let project = performance_project(project_index);
            db.sync_project(&project).expect("sync project");
            for session_index in 0..sessions_per_project {
                let state = performance_session_state(project_index, session_index);
                db.sync_session(&project.project_id, &state)
                    .expect("sync session");
            }
        }

        db
    }

    fn median_runtime_budget_ms(
        label: &str,
        iterations: usize,
        budget_ms: u64,
        mut operation: impl FnMut(),
    ) {
        for _ in 0..3 {
            operation();
        }

        let mut samples = Vec::with_capacity(iterations);
        for _ in 0..iterations {
            let started_at = Instant::now();
            operation();
            samples.push(started_at.elapsed());
        }
        samples.sort_unstable();
        let median = samples[samples.len() / 2];
        let budget = Duration::from_millis(budget_ms);

        assert!(
            median <= budget,
            "{label} median runtime {:?} exceeded {:?}",
            median,
            budget
        );
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
                title: "test title".into(),
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
    fn sync_conversation_events_replaces_existing_rows() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let first = vec![
            sample_conversation_event(1, "first"),
            sample_conversation_event(2, "second"),
        ];
        db.sync_conversation_events("sess-test-1", "claude-leader", "claude", &first)
            .expect("first sync");

        let replacement = vec![
            sample_conversation_event(1, "updated"),
            sample_conversation_event(3, "third"),
        ];
        db.sync_conversation_events("sess-test-1", "claude-leader", "claude", &replacement)
            .expect("replacement sync");

        let count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                ["sess-test-1", "claude-leader"],
                |row| row.get(0),
            )
            .expect("count conversation events");
        assert_eq!(count, 2);

        let loaded = db
            .load_conversation_events("sess-test-1", "claude-leader")
            .expect("load events");
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].sequence, 1);
        assert_eq!(loaded[1].sequence, 3);
        match &loaded[0].kind {
            ConversationEventKind::AssistantText { content } => assert_eq!(content, "updated"),
            other => panic!("unexpected event kind: {other:?}"),
        }

        db.sync_conversation_events("sess-test-1", "claude-leader", "claude", &[])
            .expect("clear events");
        let cleared_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                ["sess-test-1", "claude-leader"],
                |row| row.get(0),
            )
            .expect("count cleared conversation events");
        assert_eq!(cleared_count, 0);
    }

    #[test]
    fn clear_session_conversation_events_removes_rows_for_removed_agents() {
        let db = DaemonDb::open_in_memory().expect("open db");
        db.sync_conversation_events(
            "sess-test-1",
            "claude-leader",
            "claude",
            &[sample_conversation_event(1, "leader")],
        )
        .expect("sync leader events");

        let other_agent_events = vec![ConversationEvent {
            agent: "codex-worker".into(),
            ..sample_conversation_event(1, "worker")
        }];
        db.sync_conversation_events("sess-test-1", "codex-worker", "codex", &other_agent_events)
            .expect("sync worker events");

        clear_session_conversation_events(db.connection(), "sess-test-1")
            .expect("clear session events");
        db.sync_conversation_events(
            "sess-test-1",
            "claude-leader",
            "claude",
            &[sample_conversation_event(1, "leader")],
        )
        .expect("resync current agent");

        let total_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events WHERE session_id = ?1",
                ["sess-test-1"],
                |row| row.get(0),
            )
            .expect("count session conversation events");
        assert_eq!(total_count, 1);

        let worker_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                ["sess-test-1", "codex-worker"],
                |row| row.get(0),
            )
            .expect("count worker conversation events");
        assert_eq!(worker_count, 0);
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
                    event.sequence,
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

    #[test]
    fn health_counts_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("health_counts", 31, 5, || {
            let counts = db.health_counts().expect("health counts");
            assert_eq!(counts.0, 16);
            assert_eq!(counts.2, 128);
        });
    }

    #[test]
    fn list_project_summaries_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("list_project_summaries", 21, 20, || {
            let summaries = db.list_project_summaries().expect("project summaries");
            assert_eq!(summaries.len(), 16);
        });
    }

    #[test]
    fn list_session_summaries_full_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("list_session_summaries_full", 21, 35, || {
            let summaries = db.list_session_summaries_full().expect("session summaries");
            assert_eq!(summaries.len(), 128);
        });
    }

    #[test]
    fn resolve_session_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("resolve_session", 31, 10, || {
            let resolved = db
                .resolve_session("sess-7-5")
                .expect("resolve session")
                .expect("session present");
            assert_eq!(resolved.state.session_id, "sess-7-5");
        });
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

    #[test]
    fn mark_session_inactive_clears_active_flag() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let active_before: i32 = db
            .conn
            .query_row(
                "SELECT is_active FROM sessions WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("query active");
        assert_eq!(active_before, 1);

        db.mark_session_inactive(&state.session_id)
            .expect("mark inactive");

        let active_after: i32 = db
            .conn
            .query_row(
                "SELECT is_active FROM sessions WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("query active");
        assert_eq!(active_after, 0);
    }

    #[test]
    fn project_id_for_session_returns_correct_id() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let found = db
            .project_id_for_session(&state.session_id)
            .expect("lookup");
        assert_eq!(found.as_deref(), Some("project-abc123"));
    }

    #[test]
    fn project_id_for_session_returns_none_for_missing() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let found = db.project_id_for_session("nonexistent").expect("lookup");
        assert!(found.is_none());
    }

    #[test]
    fn ensure_project_for_dir_creates_and_returns_id() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let found = db
            .ensure_project_for_dir("/tmp/harness")
            .expect("ensure project");
        assert_eq!(found, "project-abc123");
    }

    #[test]
    fn ensure_project_for_dir_matches_context_root() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let found = db
            .ensure_project_for_dir("/tmp/data/projects/project-abc123")
            .expect("ensure by context root");
        assert_eq!(found, "project-abc123");
    }

    #[test]
    fn ensure_project_for_dir_returns_error_for_unknown() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let result = db.ensure_project_for_dir("/nonexistent/path");
        assert!(result.is_err());
    }

    #[test]
    fn load_session_state_for_mutation_returns_mutable_state() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let loaded = db
            .load_session_state_for_mutation(&state.session_id)
            .expect("load")
            .expect("present");
        assert_eq!(loaded.session_id, "sess-test-1");
        assert_eq!(loaded.agents.len(), 1);
        assert_eq!(loaded.tasks.len(), 1);
    }

    #[test]
    fn load_session_state_for_mutation_returns_none_for_missing() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let loaded = db
            .load_session_state_for_mutation("nonexistent")
            .expect("load");
        assert!(loaded.is_none());
    }

    #[test]
    fn save_session_state_persists_changes() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let mut state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("initial sync");

        state.context = "updated context".into();
        state.state_version = 2;
        db.save_session_state(&project.project_id, &state)
            .expect("save");

        let reloaded = db
            .load_session_state(&state.session_id)
            .expect("load")
            .expect("present");
        assert_eq!(reloaded.context, "updated context");
        assert_eq!(reloaded.state_version, 2);
    }

    #[test]
    fn create_session_record_inserts_active_session() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let state = sample_session_state();
        db.create_session_record(&project.project_id, &state)
            .expect("create");

        let loaded = db
            .load_session_state(&state.session_id)
            .expect("load")
            .expect("present");
        assert_eq!(loaded.session_id, "sess-test-1");

        let is_active: i32 = db
            .conn
            .query_row(
                "SELECT is_active FROM sessions WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("query active");
        assert_eq!(is_active, 1);
    }

    fn sample_resolved_session(
        project: &DiscoveredProject,
        session_id: &str,
        state_version: u64,
    ) -> super::super::index::ResolvedSession {
        let mut state = sample_session_state();
        state.session_id = session_id.into();
        state.state_version = state_version;
        super::super::index::ResolvedSession {
            project: project.clone(),
            state,
        }
    }

    #[test]
    fn reconcile_imports_new_session() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        let resolved = sample_resolved_session(&project, "new-sess", 1);

        let result = db
            .reconcile_sessions(&[project], &[resolved])
            .expect("reconcile");
        assert_eq!(result.projects, 1);
        assert_eq!(result.sessions_imported, 1);
        assert_eq!(result.sessions_skipped, 0);

        let loaded = db
            .load_session_state("new-sess")
            .expect("load")
            .expect("present");
        assert_eq!(loaded.state_version, 1);
    }

    #[test]
    fn reconcile_skips_session_with_equal_db_version() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let mut state = sample_session_state();
        state.state_version = 3;
        state.context = "daemon version".into();
        db.sync_session(&project.project_id, &state).expect("sync");

        let mut file_state = sample_session_state();
        file_state.state_version = 3;
        file_state.context = "file version".into();
        let resolved = super::super::index::ResolvedSession {
            project: project.clone(),
            state: file_state,
        };

        let result = db
            .reconcile_sessions(&[project], &[resolved])
            .expect("reconcile");
        assert_eq!(result.sessions_imported, 0);
        assert_eq!(result.sessions_skipped, 1);

        let loaded = db
            .load_session_state("sess-test-1")
            .expect("load")
            .expect("present");
        assert_eq!(loaded.context, "daemon version");
    }

    #[test]
    fn reconcile_skips_session_with_higher_db_version() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let mut state = sample_session_state();
        state.state_version = 5;
        state.context = "daemon mutated".into();
        db.sync_session(&project.project_id, &state).expect("sync");

        let mut file_state = sample_session_state();
        file_state.state_version = 2;
        file_state.context = "stale file".into();
        let resolved = super::super::index::ResolvedSession {
            project: project.clone(),
            state: file_state,
        };

        let result = db
            .reconcile_sessions(&[project], &[resolved])
            .expect("reconcile");
        assert_eq!(result.sessions_imported, 0);
        assert_eq!(result.sessions_skipped, 1);

        let loaded = db
            .load_session_state("sess-test-1")
            .expect("load")
            .expect("present");
        assert_eq!(loaded.context, "daemon mutated");
        assert_eq!(loaded.state_version, 5);
    }

    #[test]
    fn reconcile_imports_session_with_higher_file_version() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let mut state = sample_session_state();
        state.state_version = 2;
        state.context = "old db".into();
        db.sync_session(&project.project_id, &state).expect("sync");

        let mut file_state = sample_session_state();
        file_state.state_version = 5;
        file_state.context = "updated file".into();
        let resolved = super::super::index::ResolvedSession {
            project: project.clone(),
            state: file_state,
        };

        let result = db
            .reconcile_sessions(&[project], &[resolved])
            .expect("reconcile");
        assert_eq!(result.sessions_imported, 1);
        assert_eq!(result.sessions_skipped, 0);

        let loaded = db
            .load_session_state("sess-test-1")
            .expect("load")
            .expect("present");
        assert_eq!(loaded.context, "updated file");
        assert_eq!(loaded.state_version, 5);
    }

    #[test]
    fn reconcile_preserves_daemon_only_sessions() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let mut daemon_session = sample_session_state();
        daemon_session.session_id = "daemon-only".into();
        daemon_session.state_version = 3;
        daemon_session.context = "daemon created".into();
        db.sync_session(&project.project_id, &daemon_session)
            .expect("sync daemon session");

        // Reconcile with a file that has a DIFFERENT session (not daemon-only)
        let file_session = sample_resolved_session(&project, "file-only", 1);

        let result = db
            .reconcile_sessions(&[project], &[file_session])
            .expect("reconcile");
        assert_eq!(result.sessions_imported, 1);

        // daemon-only session must still exist
        let loaded = db
            .load_session_state("daemon-only")
            .expect("load")
            .expect("present");
        assert_eq!(loaded.context, "daemon created");
    }

    #[test]
    fn session_state_version_returns_none_when_missing() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let version = db.session_state_version("nonexistent").expect("query");
        assert_eq!(version, None);
    }

    #[test]
    fn session_state_version_returns_version_when_present() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");

        let mut state = sample_session_state();
        state.state_version = 7;
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let version = db.session_state_version(&state.session_id).expect("query");
        assert_eq!(version, Some(7));
    }
}
