//! Incremental agent-activity fold cache for the live conversation append path.
//!
//! `append_conversation_events` runs on every streamed ACP message. Rebuilding
//! the activity summary from the full stored transcript each time is quadratic
//! over the conversation length. This module keeps a per-agent running
//! [`daemon_snapshot::AgentActivityAccumulator`] so a steady stream of appended
//! events folds only the new events, falling back to a full rebuild whenever the
//! cache cannot be proven to match the stored prefix.

use std::collections::HashMap;

use super::{
    CliError, ConversationEvent, DaemonDb, daemon_protocol, daemon_snapshot, db_error, i64_from_u64,
};

/// Cached running activity fold for one `(session_id, agent_id)` pair.
pub(super) struct ActivityFoldEntry {
    /// Highest conversation sequence already folded into `accumulator`.
    last_sequence: i64,
    accumulator: daemon_snapshot::AgentActivityAccumulator,
}

/// In-memory activity folds keyed by `(session_id, agent_id)`.
pub(super) type ActivityFoldCache = HashMap<(String, String), ActivityFoldEntry>;

impl DaemonDb {
    /// Build the activity summary for a just-appended batch.
    ///
    /// When the cached fold reflects exactly the stored prefix (its last folded
    /// sequence equals the pre-append stored maximum) and the batch is a pure
    /// tail append beyond that prefix, only the new events are folded - O(batch)
    /// instead of O(transcript). Otherwise the summary is rebuilt from the full
    /// stored transcript and the cache is reseeded, which is byte-for-byte the
    /// pre-fold behavior. New events are folded in sequence order so the result
    /// matches a one-shot rebuild over the same prefix.
    ///
    /// # Errors
    /// Returns [`CliError`] when the stored transcript cannot be loaded.
    pub(super) fn fold_or_rebuild_activity(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
        stored_max_before: i64,
    ) -> Result<daemon_protocol::AgentToolActivitySummary, CliError> {
        let min_batch_sequence = events
            .iter()
            .map(|event| i64_from_u64(event.sequence))
            .min()
            .unwrap_or(-1);

        {
            let mut cache = self.activity_fold.borrow_mut();
            if let Some(entry) = cache.get_mut(&(session_id.to_string(), agent_id.to_string()))
                && entry.last_sequence == stored_max_before
                && min_batch_sequence > stored_max_before
            {
                fold_tail_into(entry, events, stored_max_before);
                return Ok(entry.accumulator.summary());
            }
        }

        self.rebuild_activity_fold(session_id, agent_id, runtime)
    }

    fn rebuild_activity_fold(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
    ) -> Result<daemon_protocol::AgentToolActivitySummary, CliError> {
        let merged = self.load_conversation_events(session_id, agent_id)?;
        let mut accumulator =
            daemon_snapshot::AgentActivityAccumulator::new(agent_id, runtime, None);
        let mut last_sequence = -1;
        for event in &merged {
            accumulator.apply(event);
            last_sequence = last_sequence.max(i64_from_u64(event.sequence));
        }
        let summary = accumulator.summary();
        self.activity_fold.borrow_mut().insert(
            (session_id.to_string(), agent_id.to_string()),
            ActivityFoldEntry {
                last_sequence,
                accumulator,
            },
        );
        Ok(summary)
    }

    /// Drop cached activity fold state after a path replaces stored conversation
    /// rows for a session (optionally narrowed to a single agent), forcing the
    /// next append to rebuild from the freshly written transcript.
    pub(super) fn invalidate_activity_fold(&self, session_id: &str, agent_id: Option<&str>) {
        let mut cache = self.activity_fold.borrow_mut();
        match agent_id {
            Some(agent_id) => {
                cache.remove(&(session_id.to_string(), agent_id.to_string()));
            }
            None => cache.retain(|(cached_session, _), _| cached_session != session_id),
        }
    }

    /// Highest stored conversation sequence for an agent, or `-1` when the agent
    /// has no stored events. O(log n) via the `(session_id, agent_id, sequence)`
    /// primary key, unlike a counting scan.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub(super) fn conversation_event_max_sequence(
        &self,
        session_id: &str,
        agent_id: &str,
    ) -> Result<i64, CliError> {
        self.conn
            .query_row(
                "SELECT COALESCE(MAX(sequence), -1)
                 FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                rusqlite::params![session_id, agent_id],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| db_error(format!("load conversation max sequence: {error}")))
    }
}

/// Fold every batch event beyond `stored_max_before` into `entry`, applying them
/// in ascending sequence order so the accumulator state matches a full rebuild.
fn fold_tail_into(
    entry: &mut ActivityFoldEntry,
    events: &[ConversationEvent],
    stored_max_before: i64,
) {
    let mut tail: Vec<&ConversationEvent> = events
        .iter()
        .filter(|event| i64_from_u64(event.sequence) > stored_max_before)
        .collect();
    tail.sort_by_key(|event| i64_from_u64(event.sequence));
    for event in tail {
        entry.accumulator.apply(event);
        entry.last_sequence = entry.last_sequence.max(i64_from_u64(event.sequence));
    }
}
