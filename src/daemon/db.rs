use std::borrow::Cow;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

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
            self.sync_session(
                &resolved.project.project_id,
                &resolved.state,
            )?;
            result.sessions += 1;

            import_session_log(self, &resolved.project, &resolved.state.session_id)?;
            import_session_checkpoints(self, &resolved.project, &resolved.state)?;
        }

        import_daemon_events(self)?;
        self.bump_change("global")?;

        Ok(result)
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
    pub fn list_project_summaries(
        &self,
    ) -> Result<Vec<super::protocol::ProjectSummary>, CliError> {
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
            let entry = grouped.entry(row.project_id.clone()).or_insert_with(|| {
                ProjectSummary {
                    project_id: row.project_id.clone(),
                    name: row.name.clone(),
                    project_dir: row.project_dir.clone(),
                    context_root: row.context_root.clone(),
                    active_session_count: 0,
                    total_session_count: 0,
                    worktrees: Vec::new(),
                }
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
                    s.session_id, s.context, s.status, s.created_at, s.updated_at,
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
                    context: row.get(1)?,
                    status: row.get(2)?,
                    created_at: row.get(3)?,
                    updated_at: row.get(4)?,
                    last_activity_at: row.get(5)?,
                    leader_id: row.get(6)?,
                    observe_id: row.get(7)?,
                    pending_leader_transfer_json: row.get(8)?,
                    metrics_json: row.get(9)?,
                    project_id: row.get(10)?,
                    project_name: row.get(11)?,
                    project_dir: row.get(12)?,
                    context_root: row.get(13)?,
                    checkout_id: row.get(14)?,
                    is_worktree: row.get(15)?,
                    worktree_name: row.get(16)?,
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
}

/// Summary of what was imported from file-based storage.
#[derive(Debug, Default)]
pub struct ImportResult {
    pub projects: usize,
    pub sessions: usize,
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
        let metrics = serde_json::from_str(&self.metrics_json)
            .unwrap_or_default();
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
