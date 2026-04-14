use super::{
    CliError, DaemonDb, SessionLogEntry, SessionState, TaskCheckpoint, db_error, u64_from_i64,
};

impl DaemonDb {
    /// Load session state by ID.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
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
                    u64_from_i64(row.get::<_, i64>(1)?),
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
    /// Load session state by ID for an in-place mutation.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
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
}
