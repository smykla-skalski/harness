use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

mod sql;

use self::sql::{
    ADVANCE_CHANGE_SEQUENCE_SQL, CURRENT_CHANGE_SEQUENCE_SQL, DELETE_SESSION_AGENTS_SQL,
    DELETE_SESSION_ROW_SQL, DELETE_SESSION_TASKS_SQL, ENSURE_SESSION_TIMELINE_STATE_SQL,
    INSERT_AGENT_SQL, INSERT_CHECKPOINT_SQL, INSERT_LOG_ENTRY_SQL, INSERT_TASK_SQL,
    MARK_SESSION_ACTIVE_SQL, NEXT_LOG_SEQUENCE_SQL, UPSERT_CHANGE_SQL, UPSERT_PROJECT_SQL,
    UPSERT_SESSION_SQL, UPSERT_TIMELINE_ENTRY_SQL, UPSERT_TIMELINE_STATE_SQL,
};
use super::{
    AgentRegistration, AsyncDaemonDb, BTreeMap, CliError, DiscoveredProject, SessionLogEntry,
    SessionState, StoredTimelineEntry, TaskCheckpoint, WorkItem, daemon_timeline, db_error,
    extract_transition_kind, i64_from_u64, normalize_change_scope, session_status_db_label,
    stored_timeline_entry, u64_from_i64, utc_now,
};
use crate::errors::CliErrorKind;
use crate::session::service::canonicalize_active_session_without_leader;

const LOAD_SESSION_FOR_MUTATION_SQL: &str =
    "SELECT state_json, project_id FROM sessions WHERE session_id = ?1";

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

    /// Load, mutate, and save session state under an immediate transaction.
    ///
    /// This serializes async mutation writers before they read state, avoiding
    /// lost updates when independent HTTP/WebSocket requests mutate the same
    /// session concurrently.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL, parse, or mutation failures.
    pub(crate) async fn update_session_state_immediate<F, T>(
        &self,
        session_id: &str,
        update: F,
    ) -> Result<T, CliError>
    where
        F: FnOnce(&mut SessionState) -> Result<T, CliError>,
    {
        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| {
                db_error(format!(
                    "begin async immediate session mutation transaction: {error}"
                ))
            })?;
        let row = query_as::<_, AsyncSessionMutationRow>(LOAD_SESSION_FOR_MUTATION_SQL)
            .bind(session_id)
            .fetch_optional(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "load async session for mutation {session_id}: {error}"
                ))
            })?
            .ok_or_else(|| {
                CliError::from(CliErrorKind::session_not_active(format!(
                    "session '{session_id}' not found"
                )))
            })?;
        let mut state: SessionState = serde_json::from_str(&row.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let result = update(&mut state)?;
        sync_session_in_transaction(&mut transaction, &row.project_id, &state).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit async immediate session mutation transaction: {error}"
            ))
        })?;
        Ok(result)
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
    /// Delete a session row and all cascade-dependent rows through the async DB.
    ///
    /// Returns `Ok(true)` when a row was deleted, `Ok(false)` when none matched.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn delete_session_row(&self, session_id: &str) -> Result<bool, CliError> {
        let result = query(DELETE_SESSION_ROW_SQL)
            .bind(session_id)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("delete async session row: {error}")))?;
        Ok(result.rows_affected() > 0)
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
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin async session sync transaction: {error}"))
            })?;
        sync_session_in_transaction(&mut transaction, project_id, state).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit async session sync: {error}")))?;
        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct AsyncSessionMutationRow {
    state_json: String,
    project_id: String,
}

async fn sync_session_in_transaction(
    transaction: &mut Transaction<'_, Sqlite>,
    project_id: &str,
    state: &SessionState,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut canonical_state = state.clone();
    canonicalize_active_session_without_leader(&mut canonical_state, &now);
    let state_json = serde_json::to_string(&canonical_state)
        .map_err(|error| db_error(format!("serialize async session state: {error}")))?;
    let metrics_json = serde_json::to_string(&canonical_state.metrics)
        .map_err(|error| db_error(format!("serialize async session metrics: {error}")))?;
    let pending_transfer_json = canonical_state
        .pending_leader_transfer
        .as_ref()
        .and_then(|transfer| serde_json::to_string(transfer).ok());
    let status = session_status_db_label(canonical_state.status)?;
    let is_active = i32::from(canonical_state.status.is_default_visible());

    query(UPSERT_SESSION_SQL)
        .bind(&canonical_state.session_id)
        .bind(project_id)
        .bind(canonical_state.schema_version)
        .bind(i64_from_u64(canonical_state.state_version))
        .bind(&canonical_state.title)
        .bind(&canonical_state.context)
        .bind(status)
        .bind(canonical_state.leader_id.as_deref())
        .bind(canonical_state.observe_id.as_deref())
        .bind(&canonical_state.created_at)
        .bind(&canonical_state.updated_at)
        .bind(canonical_state.last_activity_at.as_deref())
        .bind(canonical_state.archived_at.as_deref())
        .bind(pending_transfer_json.as_deref())
        .bind(metrics_json)
        .bind(state_json)
        .bind(is_active)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("upsert async session: {error}")))?;

    replace_agents(
        transaction,
        &canonical_state.session_id,
        &canonical_state.agents,
    )
    .await?;
    replace_tasks(
        transaction,
        &canonical_state.session_id,
        &canonical_state.tasks,
    )
    .await?;
    query(ENSURE_SESSION_TIMELINE_STATE_SQL)
        .bind(&canonical_state.session_id)
        .bind(&canonical_state.updated_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("ensure async session timeline state: {error}")))?;
    Ok(())
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
