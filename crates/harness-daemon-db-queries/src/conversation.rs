mod persistence;
mod preparation;

use harness_daemon_db_core::{DaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::agent::ConversationEvent;
use harness_session::index::ResolvedSession;
use harness_session::wire::AgentToolActivitySummary;
use harness_timeline::TimelinePayloadScope;

use self::persistence::{
    apply_conversation_timeline_rows, build_conversation_timeline_rows,
    conversation_timeline_rows_after, replace_session_activity, replace_session_conversation_state,
    upsert_agent_activity,
};
use crate::activity_fold::DaemonDbActivityFold;
use crate::timeline::stored_timeline_entry;
use crate::writes::SessionWriteQueries;

pub use preparation::{
    clear_session_conversation_events, extract_conversation_event_kind,
    prepare_agent_conversation_imports_and_activity, prepare_runtime_transcript_resync_for_agents,
};

/// Prepared conversation events for one agent, ready to import into the
/// database. Fields are `pub`: `harness-daemon`'s `async_conversation.rs`
/// (staying behind, not yet extracted) reads them directly.
#[derive(Debug)]
pub struct PreparedConversationEventImport {
    pub agent_id: String,
    pub runtime: String,
    pub events: Vec<ConversationEvent>,
}

/// One agent's prepared runtime-transcript resync payload.
#[derive(Debug)]
pub struct PreparedAgentTranscriptResync {
    pub agent_id: String,
    pub runtime: String,
    pub activity: AgentToolActivitySummary,
    pub events: Vec<ConversationEvent>,
}

pub trait DaemonDbConversation {
    /// Refresh runtime transcript caches from file-backed agent logs without
    /// reimporting session state through a broader file reconcile path.
    ///
    /// # Errors
    /// Returns [`CliError`] on I/O, serialization, or SQL failures.
    fn sync_runtime_transcripts(&self, resolved: &ResolvedSession) -> Result<(), CliError>;

    /// Sync conversation events for an agent into the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn sync_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError>;

    /// Append live conversation events for an agent without replacing existing
    /// transcript history.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or timeline conversion failures.
    fn append_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError>;

    /// Incrementally upsert conversation events whose sequence is greater than
    /// `after_sequence`, returning whether any conversation row changed.
    ///
    /// Events at or below the cursor are skipped entirely (no read, no write) so
    /// an unchanged transcript prefix keeps its stored row identity instead of
    /// being deleted and reinserted. Pass `-1` to consider every event, in which
    /// case a row whose stored JSON already matches is still skipped for live
    /// append idempotency.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or timeline conversion failures.
    fn upsert_conversation_events_after(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
        after_sequence: i64,
    ) -> Result<bool, CliError>;

    /// Return the stored conversation event count and highest sequence for an
    /// agent, used to drive incremental transcript resync.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn conversation_event_cursor(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<(usize, i64), CliError>;

    /// Load conversation events for a session agent from the index.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<Vec<ConversationEvent>, CliError>;

    /// Sync agent tool activity summaries for a session into the cache.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn sync_agent_activity(
        &self,
        session_id: &str,
        activities: &[AgentToolActivitySummary],
    ) -> Result<(), CliError>;

    /// Insert or update one cached agent activity summary.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn upsert_agent_activity(
        &self,
        session_id: &str,
        activity: &AgentToolActivitySummary,
    ) -> Result<(), CliError>;

    /// Load cached agent activity summaries for a session.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<AgentToolActivitySummary>, CliError>;
}

impl DaemonDbConversation for DaemonDb {
    fn sync_runtime_transcripts(&self, resolved: &ResolvedSession) -> Result<(), CliError> {
        let session_id = &resolved.state.session_id;
        let (activities, conversation_events) = prepare_agent_conversation_imports_and_activity(
            &resolved.state,
            |agent_id, runtime, session_key| {
                harness_session::index::load_conversation_events(
                    &resolved.project,
                    runtime,
                    session_key,
                    agent_id,
                )
            },
        )?;
        let timeline_rows = build_conversation_timeline_rows(session_id, &conversation_events)?;
        let transaction = self.conn.unchecked_transaction().map_err(|error| {
            db_error(format!(
                "begin runtime transcript sync transaction: {error}"
            ))
        })?;
        replace_session_activity(&transaction, session_id, &activities)?;
        replace_session_conversation_state(
            &transaction,
            session_id,
            &conversation_events,
            &timeline_rows,
        )?;
        transaction.commit().map_err(|error| {
            db_error(format!(
                "commit runtime transcript sync transaction: {error}"
            ))
        })?;
        self.invalidate_activity_fold(session_id, None);
        Ok(())
    }

    fn sync_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError> {
        let mut timeline_rows = Vec::new();
        for event in events {
            if let Some(entry) = harness_timeline::conversation_entry(
                session_id,
                agent_id,
                runtime,
                event,
                TimelinePayloadScope::Full,
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
                let kind = extract_conversation_event_kind(&kind_json);
                let json = serde_json::to_string(event).unwrap_or_default();
                statement
                    .execute(rusqlite::params![
                        session_id,
                        agent_id,
                        runtime,
                        event.timestamp,
                        harness_daemon_db_core::i64_from_u64(event.sequence),
                        kind,
                        json,
                    ])
                    .map_err(|error| db_error(format!("insert conversation event: {error}")))?;
            }
        }

        crate::timeline_store::replace_session_timeline_entries_for_prefix(
            &transaction,
            session_id,
            "conversation",
            &format!("conversation:{agent_id}:"),
            &timeline_rows,
        )?;

        transaction
            .commit()
            .map_err(|error| db_error(format!("commit conversation event sync: {error}")))?;
        self.invalidate_activity_fold(session_id, Some(agent_id));
        Ok(())
    }

    fn append_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError> {
        if events.is_empty() {
            return Ok(());
        }

        let stored_max_before = self.conversation_event_max_sequence(session_id, agent_id)?;
        let changed =
            self.upsert_conversation_events_after(session_id, agent_id, runtime, events, -1)?;
        if !changed {
            return Ok(());
        }

        let activity = self.fold_or_rebuild_activity(
            session_id,
            agent_id,
            runtime,
            events,
            stored_max_before,
        )?;
        self.upsert_agent_activity(session_id, &activity)?;
        self.bump_change(session_id)?;
        Ok(())
    }

    fn upsert_conversation_events_after(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
        after_sequence: i64,
    ) -> Result<bool, CliError> {
        let timeline_rows = conversation_timeline_rows_after(
            session_id,
            agent_id,
            runtime,
            events,
            after_sequence,
        )?;

        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin live conversation append: {error}")))?;

        let changed = self::persistence::upsert_changed_conversation_events(
            &transaction,
            session_id,
            agent_id,
            runtime,
            events,
            after_sequence,
        )?;
        apply_conversation_timeline_rows(&transaction, session_id, &timeline_rows)?;

        transaction
            .commit()
            .map_err(|error| db_error(format!("commit live conversation append: {error}")))?;

        Ok(changed)
    }

    fn conversation_event_cursor(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<(usize, i64), CliError> {
        self.conn
            .query_row(
                "SELECT COUNT(*), COALESCE(MAX(sequence), -1)
                 FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                rusqlite::params![session_id, agent_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .map(|(count, max_sequence)| {
                (harness_daemon_db_core::usize_from_i64(count), max_sequence)
            })
            .map_err(|error| db_error(format!("load conversation event cursor: {error}")))
    }

    fn load_conversation_events(
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
    fn sync_agent_activity(
        &self,
        session_id: &str,
        activities: &[AgentToolActivitySummary],
    ) -> Result<(), CliError> {
        self.invalidate_activity_fold(session_id, None);
        replace_session_activity(&self.conn, session_id, activities)
    }

    fn upsert_agent_activity(
        &self,
        session_id: &str,
        activity: &AgentToolActivitySummary,
    ) -> Result<(), CliError> {
        upsert_agent_activity(&self.conn, session_id, activity)
    }

    fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<AgentToolActivitySummary>, CliError> {
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
