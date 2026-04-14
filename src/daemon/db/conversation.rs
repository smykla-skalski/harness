use super::{DaemonDb, ConversationEvent, CliError, daemon_timeline, stored_timeline_entry, db_error, extract_transition_kind, i64_from_u64, replace_session_timeline_entries_for_prefix, daemon_protocol, utc_now, SessionState, PreparedConversationEventImport, daemon_snapshot, Connection};

impl DaemonDb {
    /// Sync conversation events for an agent into the database.
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
        let mut timeline_rows = Vec::new();
        for event in events {
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
                        i64_from_u64(event.sequence),
                        kind,
                        json,
                    ])
                    .map_err(|error| db_error(format!("insert conversation event: {error}")))?;
            }
        }

        replace_session_timeline_entries_for_prefix(
            &transaction,
            session_id,
            "conversation",
            &format!("conversation:{agent_id}:"),
            &timeline_rows,
        )?;

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
    /// Sync agent tool activity summaries for a session into the cache.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_agent_activity(
        &self,
        session_id: &str,
        activities: &[daemon_protocol::AgentToolActivitySummary],
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
    ) -> Result<Vec<daemon_protocol::AgentToolActivitySummary>, CliError> {
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
}

pub(super) fn prepare_agent_conversation_imports_and_activity<F>(
    state: &SessionState,
    mut load_events: F,
) -> Result<
    (
        Vec<daemon_protocol::AgentToolActivitySummary>,
        Vec<PreparedConversationEventImport>,
    ),
    CliError,
>
where
    F: FnMut(&str, &str, &str) -> Result<Vec<ConversationEvent>, CliError>,
{
    let mut activities = Vec::with_capacity(state.agents.len());
    let mut conversation_events = Vec::with_capacity(state.agents.len());

    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        let events = load_events(agent_id, &agent.runtime, session_key)?;
        activities.push(daemon_snapshot::agent_activity_summary_from_events(
            agent_id,
            &agent.runtime,
            agent.last_activity_at.as_deref(),
            &events,
        ));
        conversation_events.push(PreparedConversationEventImport {
            agent_id: agent_id.clone(),
            runtime: agent.runtime.clone(),
            events,
        });
    }

    Ok((activities, conversation_events))
}
pub(super) fn clear_session_conversation_events(conn: &Connection, session_id: &str) -> Result<(), CliError> {
    conn.execute(
        "DELETE FROM conversation_events WHERE session_id = ?1",
        [session_id],
    )
    .map_err(|error| db_error(format!("clear session conversation events: {error}")))?;
    Ok(())
}
