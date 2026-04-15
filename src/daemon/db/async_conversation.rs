use sqlx::{Sqlite, Transaction, query};

use super::{
    AsyncDaemonDb, CliError, ConversationEvent, PreparedConversationEventImport,
    StoredTimelineEntry, daemon_index, daemon_protocol, daemon_timeline, db_error,
    extract_transition_kind, i64_from_u64, prepare_agent_conversation_imports_and_activity,
    stored_timeline_entry, utc_now,
};

const DELETE_SESSION_ACTIVITY_SQL: &str = "DELETE FROM agent_activity_cache WHERE session_id = ?1";
const UPSERT_ACTIVITY_SQL: &str = "INSERT INTO agent_activity_cache (
    agent_id, session_id, runtime, activity_json, cached_at
) VALUES (?1, ?2, ?3, ?4, ?5)
ON CONFLICT(session_id, agent_id) DO UPDATE SET
    runtime = excluded.runtime,
    activity_json = excluded.activity_json,
    cached_at = excluded.cached_at";
const DELETE_SESSION_CONVERSATION_SQL: &str =
    "DELETE FROM conversation_events WHERE session_id = ?1";
const DELETE_SESSION_CONVERSATION_TIMELINE_SQL: &str = "DELETE FROM session_timeline_entries
    WHERE session_id = ?1
      AND source_kind = 'conversation'";
const INSERT_CONVERSATION_EVENT_SQL: &str = "INSERT INTO conversation_events (
    session_id, agent_id, runtime, timestamp, sequence, kind, event_json
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

impl AsyncDaemonDb {
    /// Refresh runtime transcript caches from file-backed agent logs without
    /// reimporting session state through the sync daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on I/O, serialization, or SQL failures.
    pub(crate) async fn sync_runtime_transcripts(
        &self,
        resolved: &daemon_index::ResolvedSession,
    ) -> Result<(), CliError> {
        let session_id = &resolved.state.session_id;
        let (activities, conversation_events) = prepare_agent_conversation_imports_and_activity(
            &resolved.state,
            |agent_id, runtime, session_key| {
                daemon_index::load_conversation_events(
                    &resolved.project,
                    runtime,
                    session_key,
                    agent_id,
                )
            },
        )?;

        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!(
                "begin async runtime transcript sync transaction: {error}"
            ))
        })?;
        sync_agent_activity(&mut transaction, session_id, &activities).await?;
        replace_session_conversation_events(&mut transaction, session_id, &conversation_events)
            .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit async runtime transcript sync transaction: {error}"
            ))
        })?;
        Ok(())
    }
}

async fn sync_agent_activity(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    activities: &[daemon_protocol::AgentToolActivitySummary],
) -> Result<(), CliError> {
    query(DELETE_SESSION_ACTIVITY_SQL)
        .bind(session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("delete async activity cache: {error}")))?;
    for activity in activities {
        let json = serde_json::to_string(activity)
            .map_err(|error| db_error(format!("serialize async activity cache: {error}")))?;
        query(UPSERT_ACTIVITY_SQL)
            .bind(&activity.agent_id)
            .bind(session_id)
            .bind(&activity.runtime)
            .bind(json)
            .bind(utc_now())
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("upsert async activity: {error}")))?;
    }
    Ok(())
}

async fn replace_session_conversation_events(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    conversation_events: &[PreparedConversationEventImport],
) -> Result<(), CliError> {
    let timeline_rows = build_conversation_timeline_rows(session_id, conversation_events)?;
    clear_session_conversation_state(transaction, session_id).await?;
    insert_conversation_imports(transaction, session_id, conversation_events).await?;
    upsert_conversation_timeline(transaction, &timeline_rows).await?;
    persist_conversation_timeline_state(transaction, session_id).await?;
    Ok(())
}

async fn clear_session_conversation_state(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
) -> Result<(), CliError> {
    query(DELETE_SESSION_CONVERSATION_SQL)
        .bind(session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear async conversation events: {error}")))?;
    query(DELETE_SESSION_CONVERSATION_TIMELINE_SQL)
        .bind(session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear async conversation timeline: {error}")))?;
    Ok(())
}

async fn insert_conversation_imports(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    conversation_events: &[PreparedConversationEventImport],
) -> Result<(), CliError> {
    for prepared in conversation_events {
        for event in &prepared.events {
            insert_conversation_event(
                transaction,
                session_id,
                &prepared.agent_id,
                &prepared.runtime,
                event,
            )
            .await?;
        }
    }
    Ok(())
}

async fn upsert_conversation_timeline(
    transaction: &mut Transaction<'_, Sqlite>,
    timeline_rows: &[StoredTimelineEntry],
) -> Result<(), CliError> {
    for entry in timeline_rows {
        upsert_timeline_entry(transaction, entry).await?;
    }
    Ok(())
}

async fn persist_conversation_timeline_state(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
) -> Result<(), CliError> {
    query(UPSERT_TIMELINE_STATE_SQL)
        .bind(session_id)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "persist async conversation timeline state for {session_id}: {error}"
            ))
        })?;
    Ok(())
}

fn build_conversation_timeline_rows(
    session_id: &str,
    conversation_events: &[PreparedConversationEventImport],
) -> Result<Vec<StoredTimelineEntry>, CliError> {
    let mut timeline_rows = Vec::new();
    for prepared in conversation_events {
        for event in &prepared.events {
            if let Some(entry) = daemon_timeline::conversation_entry(
                session_id,
                &prepared.agent_id,
                &prepared.runtime,
                event,
                daemon_timeline::TimelinePayloadScope::Full,
            )? {
                timeline_rows.push(stored_timeline_entry(
                    "conversation",
                    format!("conversation:{}:{}", prepared.agent_id, event.sequence),
                    &entry,
                )?);
            }
        }
    }
    Ok(timeline_rows)
}

async fn insert_conversation_event(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    agent_id: &str,
    runtime: &str,
    event: &ConversationEvent,
) -> Result<(), CliError> {
    let kind_json = serde_json::to_string(&event.kind)
        .map_err(|error| db_error(format!("serialize async conversation event kind: {error}")))?;
    let event_json = serde_json::to_string(event)
        .map_err(|error| db_error(format!("serialize async conversation event: {error}")))?;
    query(INSERT_CONVERSATION_EVENT_SQL)
        .bind(session_id)
        .bind(agent_id)
        .bind(runtime)
        .bind(event.timestamp.as_deref())
        .bind(i64_from_u64(event.sequence))
        .bind(extract_transition_kind(&kind_json))
        .bind(event_json)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert async conversation event: {error}")))?;
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
        .map_err(|error| db_error(format!("upsert async conversation timeline entry: {error}")))?;
    Ok(())
}
