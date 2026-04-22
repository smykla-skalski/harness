use super::{
    AgentRegistration, BTreeMap, CliError, Connection, DaemonDb, DiscoveredProject,
    SessionLogEntry, SessionState, TaskCheckpoint, WorkItem, daemon_timeline,
    db_error, extract_transition_kind, i64_from_u64, normalize_change_scope,
    session_status_db_label, stored_timeline_entry, u64_from_i64, upsert_session_timeline_entry,
    utc_now,
};
use crate::session::service::canonicalize_active_session_without_leader;

impl DaemonDb {
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
        let now = utc_now();
        let mut canonical_state = state.clone();
        canonicalize_active_session_without_leader(&mut canonical_state, &now);

        let state_json = serde_json::to_string(&canonical_state)
            .map_err(|error| db_error(format!("serialize session state: {error}")))?;
        let metrics_json = serde_json::to_string(&canonical_state.metrics)
            .map_err(|error| db_error(format!("serialize session metrics: {error}")))?;
        let pending_transfer_json = canonical_state
            .pending_leader_transfer
            .as_ref()
            .and_then(|transfer| serde_json::to_string(transfer).ok());
        let status = session_status_db_label(canonical_state.status)?;
        let is_active = i32::from(canonical_state.status.is_default_visible());

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
                    canonical_state.session_id,
                    project_id,
                    canonical_state.schema_version,
                    i64_from_u64(canonical_state.state_version),
                    canonical_state.title,
                    canonical_state.context,
                    status,
                    canonical_state.leader_id,
                    canonical_state.observe_id,
                    canonical_state.created_at,
                    canonical_state.updated_at,
                    canonical_state.last_activity_at,
                    canonical_state.archived_at,
                    pending_transfer_json,
                    metrics_json,
                    state_json,
                    is_active,
                ],
            )
            .map_err(|error| db_error(format!("upsert session: {error}")))?;

        replace_agents(
            &transaction,
            &canonical_state.session_id,
            &canonical_state.agents,
        )?;
        replace_tasks(
            &transaction,
            &canonical_state.session_id,
            &canonical_state.tasks,
        )?;
        transaction
            .execute(
                "INSERT INTO session_timeline_state (
                    session_id, revision, entry_count, newest_recorded_at,
                    oldest_recorded_at, integrity_hash, updated_at
                ) VALUES (?1, 0, 0, NULL, NULL, '', ?2)
                ON CONFLICT(session_id) DO NOTHING",
                rusqlite::params![canonical_state.session_id, canonical_state.updated_at],
            )
            .map_err(|error| db_error(format!("ensure session timeline state: {error}")))?;

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
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin append log transaction: {error}")))?;
        let sequence = if entry.sequence == 0 {
            transaction
                .query_row(
                    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM session_log WHERE session_id = ?1",
                    [&entry.session_id],
                    |row| row.get::<_, i64>(0).map(u64_from_i64),
                )
                .map_err(|error| db_error(format!("next log sequence: {error}")))?
        } else {
            entry.sequence
        };

        let inserted = transaction
            .execute(
                "INSERT OR IGNORE INTO session_log (
                    session_id, sequence, recorded_at, transition_kind,
                    transition_json, actor_id, reason
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![
                    entry.session_id,
                    i64_from_u64(sequence),
                    entry.recorded_at,
                    transition_kind,
                    transition_json,
                    entry.actor_id,
                    entry.reason,
                ],
            )
            .map_err(|error| db_error(format!("append log entry: {error}")))?;
        if inserted > 0 {
            let timeline_entry = daemon_timeline::log_entry_timeline_entry(
                &SessionLogEntry {
                    sequence,
                    ..entry.clone()
                },
                daemon_timeline::TimelinePayloadScope::Full,
            )?;
            upsert_session_timeline_entry(
                &transaction,
                &stored_timeline_entry("log", format!("log:{sequence}"), &timeline_entry)?,
            )?;
        }
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit append log transaction: {error}")))?;
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
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin append checkpoint transaction: {error}")))?;
        let inserted = transaction
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
        if inserted > 0 {
            let entry = daemon_timeline::checkpoint_entry(
                session_id,
                checkpoint,
                daemon_timeline::TimelinePayloadScope::Full,
            )?;
            upsert_session_timeline_entry(
                &transaction,
                &stored_timeline_entry(
                    "checkpoint",
                    format!("checkpoint:{}", checkpoint.checkpoint_id),
                    &entry,
                )?,
            )?;
        }
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit append checkpoint transaction: {error}")))?;
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
        let normalized_scope = normalize_change_scope(scope);
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin change bump transaction: {error}")))?;
        transaction
            .execute(
                "UPDATE change_tracking_state
                 SET last_seq = last_seq + 1
                 WHERE singleton = 1",
                [],
            )
            .map_err(|error| db_error(format!("advance change sequence: {error}")))?;
        let change_seq = transaction
            .query_row(
                "SELECT last_seq FROM change_tracking_state WHERE singleton = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| db_error(format!("read change sequence: {error}")))?;
        transaction
            .execute(
                "INSERT INTO change_tracking (scope, version, updated_at, change_seq)
                 VALUES (?1, 1, ?2, ?3)
                 ON CONFLICT(scope) DO UPDATE SET
                     version = version + 1,
                     updated_at = excluded.updated_at,
                     change_seq = excluded.change_seq",
                rusqlite::params![normalized_scope.as_ref(), utc_now(), change_seq],
            )
            .map_err(|error| db_error(format!("bump change: {error}")))?;
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit change bump transaction: {error}")))?;
        Ok(())
    }

    /// Delete a session row and all cascade-dependent rows.
    ///
    /// Relies on `ON DELETE CASCADE` foreign keys in the schema (agents, tasks,
    /// log, signals, timeline, etc.). Returns `Ok(true)` when a row was deleted,
    /// `Ok(false)` when no row matched.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn delete_session_row(&self, session_id: &str) -> Result<bool, CliError> {
        const DELETE_SESSION_ROW_SQL: &str = "DELETE FROM sessions WHERE session_id = ?1";
        let rows_affected = self
            .conn
            .execute(DELETE_SESSION_ROW_SQL, [session_id])
            .map_err(|error| db_error(format!("delete session row: {error}")))?;
        Ok(rows_affected > 0)
    }

    /// Return the most recent change-tracking sequence value.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn current_change_sequence(&self) -> Result<i64, CliError> {
        self.conn
            .query_row(
                "SELECT last_seq FROM change_tracking_state WHERE singleton = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| db_error(format!("read current change sequence: {error}")))
    }
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
