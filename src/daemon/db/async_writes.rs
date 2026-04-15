use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::{
    AgentRegistration, AsyncDaemonDb, BTreeMap, CliError, DiscoveredProject, SessionLogEntry,
    SessionState, SessionStatus, StoredTimelineEntry, TaskCheckpoint, WorkItem, daemon_timeline,
    db_error, extract_transition_kind, i64_from_u64, normalize_change_scope, stored_timeline_entry,
    u64_from_i64, utc_now,
};

const UPSERT_PROJECT_SQL: &str = "INSERT INTO projects (
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
    updated_at = excluded.updated_at";
const UPSERT_SESSION_SQL: &str = "INSERT INTO sessions (
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
    is_active = excluded.is_active";
const ENSURE_SESSION_TIMELINE_STATE_SQL: &str = "INSERT INTO session_timeline_state (
    session_id, revision, entry_count, newest_recorded_at,
    oldest_recorded_at, integrity_hash, updated_at
) VALUES (?1, 0, 0, NULL, NULL, '', ?2)
ON CONFLICT(session_id) DO NOTHING";
const DELETE_SESSION_AGENTS_SQL: &str = "DELETE FROM agents WHERE session_id = ?1";
const INSERT_AGENT_SQL: &str = "INSERT INTO agents (
    agent_id, session_id, name, runtime, role, capabilities_json,
    status, agent_session_id, joined_at, updated_at,
    last_activity_at, current_task_id, runtime_capabilities_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)";
const DELETE_SESSION_TASKS_SQL: &str = "DELETE FROM tasks WHERE session_id = ?1";
const INSERT_TASK_SQL: &str = "INSERT INTO tasks (
    task_id, session_id, title, context, severity, status,
    assigned_to, created_at, updated_at, created_by,
    suggested_fix, source, blocked_reason, completed_at,
    notes_json, checkpoint_summary_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)";
const INSERT_CHECKPOINT_SQL: &str = "INSERT OR IGNORE INTO task_checkpoints (
    checkpoint_id, task_id, session_id, recorded_at,
    actor_id, summary, progress
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";
const MARK_SESSION_ACTIVE_SQL: &str = "UPDATE sessions SET is_active = 1 WHERE session_id = ?1";
const NEXT_LOG_SEQUENCE_SQL: &str =
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM session_log WHERE session_id = ?1";
const INSERT_LOG_ENTRY_SQL: &str = "INSERT OR IGNORE INTO session_log (
    session_id, sequence, recorded_at, transition_kind,
    transition_json, actor_id, reason
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";
const UPSERT_TIMELINE_ENTRY_SQL: &str = "INSERT INTO session_timeline_entries (
    session_id, entry_id, source_kind, source_key, recorded_at, kind,
    agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
ON CONFLICT(session_id, source_kind, source_key) DO UPDATE SET
    entry_id = excluded.entry_id,
    recorded_at = excluded.recorded_at,
    kind = excluded.kind,
    agent_id = excluded.agent_id,
    task_id = excluded.task_id,
    summary = excluded.summary,
    payload_json = excluded.payload_json,
    sort_recorded_at = excluded.sort_recorded_at,
    sort_tiebreaker = excluded.sort_tiebreaker";
const UPSERT_TIMELINE_STATE_SQL: &str = "INSERT INTO session_timeline_state (
    session_id, revision, entry_count, newest_recorded_at,
    oldest_recorded_at, integrity_hash, updated_at
) VALUES (
    ?1,
    1,
    (SELECT COUNT(*) FROM session_timeline_entries WHERE session_id = ?1),
    (SELECT MAX(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    (SELECT MIN(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    '',
    ?2
)
ON CONFLICT(session_id) DO UPDATE SET
    revision = revision + 1,
    entry_count = (SELECT COUNT(*) FROM session_timeline_entries WHERE session_id = ?1),
    newest_recorded_at = (SELECT MAX(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    oldest_recorded_at = (SELECT MIN(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    updated_at = excluded.updated_at";
const ADVANCE_CHANGE_SEQUENCE_SQL: &str = "
UPDATE change_tracking_state
SET last_seq = last_seq + 1
WHERE singleton = 1";
const CURRENT_CHANGE_SEQUENCE_SQL: &str =
    "SELECT last_seq FROM change_tracking_state WHERE singleton = 1";
const UPSERT_CHANGE_SQL: &str =
    "INSERT INTO change_tracking (scope, version, updated_at, change_seq)
VALUES (?1, 1, ?2, ?3)
ON CONFLICT(scope) DO UPDATE SET
    version = version + 1,
    updated_at = excluded.updated_at,
    change_seq = excluded.change_seq";

impl AsyncDaemonDb {
    /// Upsert a discovered project through the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn sync_project(&self, project: &DiscoveredProject) -> Result<(), CliError> {
        let now = utc_now();
        query(UPSERT_PROJECT_SQL)
            .bind(&project.project_id)
            .bind(&project.name)
            .bind(
                project
                    .project_dir
                    .as_ref()
                    .map(|path| path.display().to_string()),
            )
            .bind(
                project
                    .repository_root
                    .as_ref()
                    .map(|path| path.display().to_string()),
            )
            .bind(&project.checkout_id)
            .bind(&project.checkout_name)
            .bind(project.context_root.display().to_string())
            .bind(project.is_worktree)
            .bind(project.worktree_name.as_deref())
            .bind(Option::<String>::None)
            .bind(now)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("sync async project: {error}")))?;
        Ok(())
    }

    /// Upsert a session state through the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn save_session_state(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        self.sync_session(project_id, state).await
    }

    /// Insert a new session record and mark it active.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn create_session_record(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        self.sync_session(project_id, state).await?;
        query(MARK_SESSION_ACTIVE_SQL)
            .bind(&state.session_id)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("mark async session active: {error}")))?;
        Ok(())
    }

    /// Append a session log entry and keep the canonical timeline ledger in sync.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError> {
        let transition_json = serde_json::to_string(&entry.transition)
            .map_err(|error| db_error(format!("serialize async log transition: {error}")))?;
        let transition_kind = extract_transition_kind(&transition_json);
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin async append log transaction: {error}"))
            })?;
        let sequence = next_log_sequence(&mut transaction, entry).await?;
        if insert_log_entry(
            &mut transaction,
            entry,
            sequence,
            &transition_json,
            &transition_kind,
        )
        .await?
        {
            persist_log_timeline(&mut transaction, entry, sequence).await?;
        }

        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit async append log transaction: {error}")))?;
        Ok(())
    }

    /// Append a task checkpoint and keep the canonical timeline ledger in sync.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn append_checkpoint(
        &self,
        session_id: &str,
        checkpoint: &TaskCheckpoint,
    ) -> Result<(), CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!(
                "begin async append checkpoint transaction: {error}"
            ))
        })?;
        let inserted = query(INSERT_CHECKPOINT_SQL)
            .bind(&checkpoint.checkpoint_id)
            .bind(&checkpoint.task_id)
            .bind(session_id)
            .bind(&checkpoint.recorded_at)
            .bind(&checkpoint.actor_id)
            .bind(&checkpoint.summary)
            .bind(i64::from(checkpoint.progress))
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("append async checkpoint: {error}")))?
            .rows_affected();
        if inserted > 0 {
            let entry = daemon_timeline::checkpoint_entry(
                session_id,
                checkpoint,
                daemon_timeline::TimelinePayloadScope::Full,
            )?;
            let stored = stored_timeline_entry(
                "checkpoint",
                format!("checkpoint:{}", checkpoint.checkpoint_id),
                &entry,
            )?;
            upsert_timeline_entry(&mut transaction, &stored).await?;
            query(UPSERT_TIMELINE_STATE_SQL)
                .bind(session_id)
                .bind(utc_now())
                .execute(transaction.as_mut())
                .await
                .map_err(|error| {
                    db_error(format!("persist async checkpoint timeline state: {error}"))
                })?;
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit async append checkpoint transaction: {error}"
            ))
        })?;
        Ok(())
    }
    /// Increment one change-tracking scope through the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn bump_change(&self, scope: &str) -> Result<(), CliError> {
        let normalized_scope = normalize_change_scope(scope);
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin async change bump transaction: {error}"))
            })?;
        query(ADVANCE_CHANGE_SEQUENCE_SQL)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("advance async change sequence: {error}")))?;
        let change_seq = query_scalar::<_, i64>(CURRENT_CHANGE_SEQUENCE_SQL)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("read async change sequence: {error}")))?;
        query(UPSERT_CHANGE_SQL)
            .bind(normalized_scope.as_ref())
            .bind(utc_now())
            .bind(change_seq)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("bump async change: {error}")))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit async change bump transaction: {error}")))?;
        Ok(())
    }

    async fn sync_session(&self, project_id: &str, state: &SessionState) -> Result<(), CliError> {
        let state_json = serde_json::to_string(state)
            .map_err(|error| db_error(format!("serialize async session state: {error}")))?;
        let metrics_json = serde_json::to_string(&state.metrics)
            .map_err(|error| db_error(format!("serialize async session metrics: {error}")))?;
        let pending_transfer_json = state
            .pending_leader_transfer
            .as_ref()
            .and_then(|transfer| serde_json::to_string(transfer).ok());
        let is_active = i32::from(state.status == SessionStatus::Active);

        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin async session sync transaction: {error}"))
            })?;

        query(UPSERT_SESSION_SQL)
            .bind(&state.session_id)
            .bind(project_id)
            .bind(state.schema_version)
            .bind(i64_from_u64(state.state_version))
            .bind(&state.title)
            .bind(&state.context)
            .bind(format!("{:?}", state.status).to_lowercase())
            .bind(state.leader_id.as_deref())
            .bind(state.observe_id.as_deref())
            .bind(&state.created_at)
            .bind(&state.updated_at)
            .bind(state.last_activity_at.as_deref())
            .bind(state.archived_at.as_deref())
            .bind(pending_transfer_json.as_deref())
            .bind(metrics_json)
            .bind(state_json)
            .bind(is_active)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("upsert async session: {error}")))?;

        replace_agents(&mut transaction, &state.session_id, &state.agents).await?;
        replace_tasks(&mut transaction, &state.session_id, &state.tasks).await?;
        query(ENSURE_SESSION_TIMELINE_STATE_SQL)
            .bind(&state.session_id)
            .bind(&state.updated_at)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("ensure async session timeline state: {error}")))?;

        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit async session sync: {error}")))?;
        Ok(())
    }
}

async fn replace_agents(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    agents: &BTreeMap<String, AgentRegistration>,
) -> Result<(), CliError> {
    query(DELETE_SESSION_AGENTS_SQL)
        .bind(session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("delete async agents: {error}")))?;

    for (agent_id, agent) in agents {
        let capabilities_json = serde_json::to_string(&agent.capabilities).unwrap_or_default();
        let runtime_capabilities_json =
            serde_json::to_string(&agent.runtime_capabilities).unwrap_or_default();

        query(INSERT_AGENT_SQL)
            .bind(agent_id)
            .bind(session_id)
            .bind(&agent.name)
            .bind(&agent.runtime)
            .bind(format!("{:?}", agent.role).to_lowercase())
            .bind(capabilities_json)
            .bind(format!("{:?}", agent.status).to_lowercase())
            .bind(agent.agent_session_id.as_deref())
            .bind(&agent.joined_at)
            .bind(&agent.updated_at)
            .bind(agent.last_activity_at.as_deref())
            .bind(agent.current_task_id.as_deref())
            .bind(runtime_capabilities_json)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("insert async agent {agent_id}: {error}")))?;
    }
    Ok(())
}

async fn next_log_sequence(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &SessionLogEntry,
) -> Result<u64, CliError> {
    if entry.sequence != 0 {
        return Ok(entry.sequence);
    }
    query_scalar::<_, i64>(NEXT_LOG_SEQUENCE_SQL)
        .bind(&entry.session_id)
        .fetch_one(transaction.as_mut())
        .await
        .map(u64_from_i64)
        .map_err(|error| db_error(format!("next async log sequence: {error}")))
}

async fn insert_log_entry(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &SessionLogEntry,
    sequence: u64,
    transition_json: &str,
    transition_kind: &str,
) -> Result<bool, CliError> {
    query(INSERT_LOG_ENTRY_SQL)
        .bind(&entry.session_id)
        .bind(i64_from_u64(sequence))
        .bind(&entry.recorded_at)
        .bind(transition_kind)
        .bind(transition_json)
        .bind(entry.actor_id.as_deref())
        .bind(entry.reason.as_deref())
        .execute(transaction.as_mut())
        .await
        .map(|result| result.rows_affected() > 0)
        .map_err(|error| db_error(format!("append async log entry: {error}")))
}

async fn persist_log_timeline(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &SessionLogEntry,
    sequence: u64,
) -> Result<(), CliError> {
    let timeline_entry = daemon_timeline::log_entry_timeline_entry(
        &SessionLogEntry {
            sequence,
            ..entry.clone()
        },
        daemon_timeline::TimelinePayloadScope::Full,
    )?;
    let stored = stored_timeline_entry("log", format!("log:{sequence}"), &timeline_entry)?;
    upsert_timeline_entry(transaction, &stored).await?;
    query(UPSERT_TIMELINE_STATE_SQL)
        .bind(&entry.session_id)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("persist async timeline state: {error}")))?;
    Ok(())
}

async fn replace_tasks(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    tasks: &BTreeMap<String, WorkItem>,
) -> Result<(), CliError> {
    query(DELETE_SESSION_TASKS_SQL)
        .bind(session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("delete async tasks: {error}")))?;

    for (task_id, task) in tasks {
        let notes_json = serde_json::to_string(&task.notes).unwrap_or_default();
        let checkpoint_summary_json = task
            .checkpoint_summary
            .as_ref()
            .and_then(|summary| serde_json::to_string(summary).ok());

        query(INSERT_TASK_SQL)
            .bind(task_id)
            .bind(session_id)
            .bind(&task.title)
            .bind(task.context.as_deref())
            .bind(format!("{:?}", task.severity).to_lowercase())
            .bind(format!("{:?}", task.status).to_lowercase())
            .bind(task.assigned_to.as_deref())
            .bind(&task.created_at)
            .bind(&task.updated_at)
            .bind(&task.created_by)
            .bind(task.suggested_fix.as_deref())
            .bind(format!("{:?}", task.source).to_lowercase())
            .bind(task.blocked_reason.as_deref())
            .bind(task.completed_at.as_deref())
            .bind(notes_json)
            .bind(checkpoint_summary_json.as_deref())
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("insert async task {task_id}: {error}")))?;
    }
    Ok(())
}

async fn upsert_timeline_entry(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &StoredTimelineEntry,
) -> Result<(), CliError> {
    query(UPSERT_TIMELINE_ENTRY_SQL)
        .bind(&entry.session_id)
        .bind(&entry.entry_id)
        .bind(&entry.source_kind)
        .bind(&entry.source_key)
        .bind(&entry.recorded_at)
        .bind(&entry.kind)
        .bind(entry.agent_id.as_deref())
        .bind(entry.task_id.as_deref())
        .bind(&entry.summary)
        .bind(&entry.payload_json)
        .bind(&entry.sort_recorded_at)
        .bind(&entry.sort_tiebreaker)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("upsert async timeline entry: {error}")))?;
    Ok(())
}
