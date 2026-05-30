use super::super::{
    StoredTimelineEntry, bump_session_timeline_state, replace_session_timeline_entries_for_prefix,
    upsert_session_timeline_entry_row,
};
use super::{
    CliError, Connection, ConversationEvent, OptionalExtension, PreparedConversationEventImport,
    clear_session_conversation_events, daemon_protocol, daemon_timeline, db_error,
    extract_conversation_event_kind, i64_from_u64, stored_timeline_entry, utc_now,
};

pub(super) fn replace_session_activity(
    conn: &Connection,
    session_id: &str,
    activities: &[daemon_protocol::AgentToolActivitySummary],
) -> Result<(), CliError> {
    conn.execute(
        "DELETE FROM agent_activity_cache WHERE session_id = ?1",
        [session_id],
    )
    .map_err(|error| db_error(format!("delete activity cache: {error}")))?;

    for activity in activities {
        upsert_agent_activity(conn, session_id, activity)?;
    }
    Ok(())
}

pub(super) fn upsert_agent_activity(
    conn: &Connection,
    session_id: &str,
    activity: &daemon_protocol::AgentToolActivitySummary,
) -> Result<(), CliError> {
    let json = serde_json::to_string(activity).unwrap_or_default();
    let existing_json = conn
        .query_row(
            "SELECT activity_json
             FROM agent_activity_cache
             WHERE session_id = ?1 AND agent_id = ?2",
            rusqlite::params![session_id, activity.agent_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| db_error(format!("load cached activity: {error}")))?;
    if existing_json.as_deref() == Some(json.as_str()) {
        return Ok(());
    }

    conn.execute(
        "INSERT INTO agent_activity_cache (agent_id, session_id, runtime, activity_json, cached_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(session_id, agent_id) DO UPDATE SET
             runtime = excluded.runtime,
             activity_json = excluded.activity_json,
             cached_at = excluded.cached_at",
        rusqlite::params![
            activity.agent_id,
            session_id,
            activity.runtime,
            json,
            utc_now(),
        ],
    )
    .map_err(|error| db_error(format!("upsert activity: {error}")))?;
    Ok(())
}

pub(super) fn conversation_event_json(
    conn: &Connection,
    session_id: &str,
    agent_id: &str,
    sequence: u64,
) -> Result<Option<String>, CliError> {
    conn.query_row(
        "SELECT event_json
         FROM conversation_events
         WHERE session_id = ?1
           AND agent_id = ?2
           AND sequence = ?3",
        rusqlite::params![session_id, agent_id, i64_from_u64(sequence)],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .map_err(|error| db_error(format!("load existing conversation event: {error}")))
}

pub(super) fn replace_session_conversation_state(
    transaction: &Connection,
    session_id: &str,
    conversation_events: &[PreparedConversationEventImport],
    timeline_rows: &[StoredTimelineEntry],
) -> Result<(), CliError> {
    clear_session_conversation_events(transaction, session_id)?;
    transaction
        .execute(
            "DELETE FROM session_timeline_entries
             WHERE session_id = ?1 AND source_kind = 'conversation'",
            [session_id],
        )
        .map_err(|error| db_error(format!("clear session conversation timeline: {error}")))?;

    let mut statement = transaction
        .prepare(
            "INSERT INTO conversation_events
                (session_id, agent_id, runtime, timestamp, sequence, kind, event_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )
        .map_err(|error| db_error(format!("prepare conversation import insert: {error}")))?;
    for prepared in conversation_events {
        for event in &prepared.events {
            let kind_json = serde_json::to_string(&event.kind).unwrap_or_default();
            let json = serde_json::to_string(event).unwrap_or_default();
            statement
                .execute(rusqlite::params![
                    session_id,
                    prepared.agent_id,
                    prepared.runtime,
                    event.timestamp,
                    i64_from_u64(event.sequence),
                    extract_conversation_event_kind(&kind_json),
                    json,
                ])
                .map_err(|error| db_error(format!("insert conversation import event: {error}")))?;
        }
    }
    replace_session_timeline_entries_for_prefix(
        transaction,
        session_id,
        "conversation",
        "conversation:",
        timeline_rows,
    )?;
    Ok(())
}

pub(super) fn build_conversation_timeline_rows(
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

/// Build timeline rows for conversation events whose sequence exceeds
/// `after_sequence`, skipping events at or below the cursor.
pub(super) fn conversation_timeline_rows_after(
    session_id: &str,
    agent_id: &str,
    runtime: &str,
    events: &[ConversationEvent],
    after_sequence: i64,
) -> Result<Vec<StoredTimelineEntry>, CliError> {
    let mut timeline_rows = Vec::new();
    for event in events {
        if i64_from_u64(event.sequence) <= after_sequence {
            continue;
        }
        if let Some(entry) = daemon_timeline::conversation_entry(
            session_id,
            agent_id,
            runtime,
            event,
            daemon_timeline::TimelinePayloadScope::Full,
        )? {
            timeline_rows.push(stored_timeline_entry(
                "conversation",
                format!("conversation:{agent_id}:{}", event.sequence),
                &entry,
            )?);
        }
    }
    Ok(timeline_rows)
}

/// Upsert conversation events above `after_sequence` whose stored JSON differs,
/// returning whether any row changed.
pub(super) fn upsert_changed_conversation_events(
    transaction: &Connection,
    session_id: &str,
    agent_id: &str,
    runtime: &str,
    events: &[ConversationEvent],
    after_sequence: i64,
) -> Result<bool, CliError> {
    let mut statement = transaction
        .prepare(
            "INSERT INTO conversation_events
                (session_id, agent_id, runtime, timestamp, sequence, kind, event_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(session_id, agent_id, sequence) DO UPDATE SET
                 runtime = excluded.runtime,
                 timestamp = excluded.timestamp,
                 kind = excluded.kind,
                 event_json = excluded.event_json",
        )
        .map_err(|error| db_error(format!("prepare live conversation upsert: {error}")))?;

    let mut changed = false;
    for event in events {
        if i64_from_u64(event.sequence) <= after_sequence {
            continue;
        }
        let kind_json = serde_json::to_string(&event.kind).unwrap_or_default();
        let json = serde_json::to_string(event).unwrap_or_default();
        if conversation_event_json(transaction, session_id, agent_id, event.sequence)?.as_deref()
            == Some(json.as_str())
        {
            continue;
        }
        statement
            .execute(rusqlite::params![
                session_id,
                agent_id,
                runtime,
                event.timestamp,
                i64_from_u64(event.sequence),
                extract_conversation_event_kind(&kind_json),
                json,
            ])
            .map_err(|error| db_error(format!("upsert live conversation event: {error}")))?;
        changed = true;
    }
    Ok(changed)
}

/// Apply timeline rows for a live conversation append, bumping the session
/// timeline revision when any row changed.
pub(super) fn apply_conversation_timeline_rows(
    transaction: &Connection,
    session_id: &str,
    timeline_rows: &[StoredTimelineEntry],
) -> Result<(), CliError> {
    let mut timeline_changed = false;
    for entry in timeline_rows {
        if upsert_session_timeline_entry_row(transaction, entry)? {
            timeline_changed = true;
        }
    }
    if timeline_changed {
        bump_session_timeline_state(transaction, session_id)?;
    }
    Ok(())
}
