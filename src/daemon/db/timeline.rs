use super::{
    CliError, DaemonDb, StoredTimelineEntry, TimelineEntry, daemon_index, daemon_timeline,
    db_error, replace_all_session_timeline_entries,
};
#[cfg(test)]
use super::{
    OptionalExtension, SessionTimelineStateRow, TimelineCursor, TimelineWindowRequest,
    TimelineWindowResponse, usize_from_i64,
};

impl DaemonDb {
    #[cfg(test)]
    pub(crate) fn load_session_timeline_window(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
    ) -> Result<Option<TimelineWindowResponse>, CliError> {
        let Some(state) = self.load_session_timeline_state(session_id)? else {
            return Ok(None);
        };

        let payload_scope = match request.scope.as_deref() {
            Some("summary") => daemon_timeline::TimelinePayloadScope::Summary,
            _ => daemon_timeline::TimelinePayloadScope::Full,
        };
        let limit = request.limit.unwrap_or(state.entry_count).max(1);
        let latest_window_end = state.entry_count.min(limit);

        if request.known_revision == Some(state.revision)
            && request.before.is_none()
            && request.after.is_none()
        {
            return Ok(Some(TimelineWindowResponse {
                revision: state.revision,
                total_count: state.entry_count,
                window_start: 0,
                window_end: latest_window_end,
                has_older: latest_window_end < state.entry_count,
                has_newer: false,
                oldest_cursor: self
                    .load_timeline_cursor_at_offset(session_id, latest_window_end.checked_sub(1))?,
                newest_cursor: self.load_timeline_cursor_at_offset(session_id, Some(0))?,
                entries: None,
                unchanged: true,
            }));
        }

        let window_start = if let Some(before) = &request.before {
            self.load_timeline_cursor_offset(session_id, before)?
                .map_or(state.entry_count, |offset| offset.saturating_add(1))
        } else if let Some(after) = &request.after {
            self.load_timeline_cursor_offset(session_id, after)?
                .unwrap_or(0)
                .saturating_sub(limit)
        } else {
            0
        };
        let window_rows = if let Some(after) = &request.after {
            let window_end = self
                .load_timeline_cursor_offset(session_id, after)?
                .unwrap_or(0);
            let window_start = window_end.saturating_sub(limit);
            self.load_timeline_entries_range(session_id, window_start, window_end - window_start)?
        } else {
            self.load_timeline_entries_range(
                session_id,
                window_start,
                state.entry_count.saturating_sub(window_start).min(limit),
            )?
        };
        let entries = window_rows
            .into_iter()
            .map(|row| row.into_timeline_entry(payload_scope))
            .collect::<Result<Vec<_>, _>>()?;
        let window_end = window_start + entries.len();

        Ok(Some(TimelineWindowResponse {
            revision: state.revision,
            total_count: state.entry_count,
            window_start,
            window_end,
            has_older: window_end < state.entry_count,
            has_newer: window_start > 0,
            oldest_cursor: entries.last().map(cursor_from_timeline_entry),
            newest_cursor: entries.first().map(cursor_from_timeline_entry),
            entries: Some(entries),
            unchanged: false,
        }))
    }

    /// Rebuild the canonical timeline ledger from the current resolved session.
    ///
    /// # Errors
    /// Returns [`CliError`] when timeline materialization or SQL writes fail.
    pub(crate) fn rebuild_session_timeline_from_resolved(
        &self,
        resolved: &daemon_index::ResolvedSession,
    ) -> Result<(), CliError> {
        let entries = daemon_timeline::session_timeline_from_resolved_with_db_scope(
            resolved,
            self,
            daemon_timeline::TimelinePayloadScope::Full,
        )?;
        let stored_entries = entries
            .iter()
            .map(stored_timeline_entry_for_rebuild)
            .collect::<Result<Vec<_>, _>>()?;
        replace_all_session_timeline_entries(
            &self.conn,
            &resolved.state.session_id,
            &stored_entries,
        )
    }
    #[cfg(test)]
    fn load_session_timeline_state(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionTimelineStateRow>, CliError> {
        self.conn
            .query_row(
                "SELECT session_id, revision, entry_count, newest_recorded_at,
                        oldest_recorded_at, integrity_hash, updated_at
                 FROM session_timeline_state
                 WHERE session_id = ?1",
                [session_id],
                |row| {
                    Ok(SessionTimelineStateRow {
                        session_id: row.get(0)?,
                        revision: row.get(1)?,
                        entry_count: row.get::<_, i64>(2).map(usize_from_i64)?,
                        newest_recorded_at: row.get(3)?,
                        oldest_recorded_at: row.get(4)?,
                        integrity_hash: row.get(5)?,
                        updated_at: row.get(6)?,
                    })
                },
            )
            .optional()
            .map_err(|error| db_error(format!("load session timeline state: {error}")))
    }

    #[cfg(test)]
    fn load_timeline_cursor_offset(
        &self,
        session_id: &str,
        cursor: &TimelineCursor,
    ) -> Result<Option<usize>, CliError> {
        let exists = self
            .conn
            .query_row(
                "SELECT 1
                 FROM session_timeline_entries
                 WHERE session_id = ?1
                   AND sort_recorded_at = ?2
                   AND sort_tiebreaker = ?3",
                rusqlite::params![session_id, cursor.recorded_at, cursor.entry_id],
                |_| Ok(()),
            )
            .optional()
            .map_err(|error| db_error(format!("check timeline cursor: {error}")))?;
        if exists.is_none() {
            return Ok(None);
        }

        self.conn
            .query_row(
                "SELECT COUNT(*)
                 FROM session_timeline_entries
                 WHERE session_id = ?1
                   AND (
                       sort_recorded_at > ?2
                       OR (sort_recorded_at = ?2 AND sort_tiebreaker > ?3)
                   )",
                rusqlite::params![session_id, cursor.recorded_at, cursor.entry_id],
                |row| row.get::<_, i64>(0).map(usize_from_i64),
            )
            .map(Some)
            .map_err(|error| db_error(format!("load timeline cursor offset: {error}")))
    }

    #[cfg(test)]
    fn load_timeline_entries_range(
        &self,
        session_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<StoredTimelineEntry>, CliError> {
        if limit == 0 {
            return Ok(Vec::new());
        }

        let mut statement = self
            .conn
            .prepare(
                "SELECT session_id, entry_id, source_kind, source_key, recorded_at, kind,
                        agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
                 FROM session_timeline_entries
                 WHERE session_id = ?1
                 ORDER BY sort_recorded_at DESC, sort_tiebreaker DESC
                 LIMIT ?2 OFFSET ?3",
            )
            .map_err(|error| db_error(format!("prepare timeline range: {error}")))?;
        let rows = statement
            .query_map(
                rusqlite::params![
                    session_id,
                    i64::try_from(limit).unwrap_or(i64::MAX),
                    i64::try_from(offset).unwrap_or(i64::MAX)
                ],
                stored_timeline_entry_from_row,
            )
            .map_err(|error| db_error(format!("query timeline range: {error}")))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read timeline range row: {error}")))
    }

    #[cfg(test)]
    fn load_timeline_cursor_at_offset(
        &self,
        session_id: &str,
        offset: Option<usize>,
    ) -> Result<Option<TimelineCursor>, CliError> {
        let Some(offset) = offset else {
            return Ok(None);
        };
        self.load_timeline_entries_range(session_id, offset, 1)
            .map(|mut entries| {
                entries.pop().map(|entry| TimelineCursor {
                    recorded_at: entry.recorded_at,
                    entry_id: entry.entry_id,
                })
            })
    }
}

pub(super) fn stored_timeline_entry(
    source_kind: &str,
    source_key: String,
    entry: &TimelineEntry,
) -> Result<StoredTimelineEntry, CliError> {
    Ok(StoredTimelineEntry {
        session_id: entry.session_id.clone(),
        entry_id: entry.entry_id.clone(),
        source_kind: source_kind.to_string(),
        source_key,
        recorded_at: entry.recorded_at.clone(),
        kind: entry.kind.clone(),
        agent_id: entry.agent_id.clone(),
        task_id: entry.task_id.clone(),
        summary: entry.summary.clone(),
        payload_json: serde_json::to_string(&entry.payload)
            .map_err(|error| db_error(format!("serialize timeline payload: {error}")))?,
        sort_recorded_at: entry.recorded_at.clone(),
        sort_tiebreaker: entry.entry_id.clone(),
    })
}

pub(super) fn stored_timeline_entry_for_rebuild(
    entry: &TimelineEntry,
) -> Result<StoredTimelineEntry, CliError> {
    let (source_kind, source_key) = timeline_source_identity(entry);
    stored_timeline_entry(source_kind, source_key, entry)
}

fn timeline_source_identity(entry: &TimelineEntry) -> (&'static str, String) {
    if let Some(sequence) = entry.entry_id.strip_prefix("log-") {
        return ("log", format!("log:{sequence}"));
    }
    if entry.kind == "task_checkpoint" {
        return ("checkpoint", format!("checkpoint:{}", entry.entry_id));
    }
    if let Some(signal_id) = entry.entry_id.strip_prefix("signal-ack-") {
        return ("signal_ack", format!("signal_ack:{signal_id}"));
    }
    if let Some(observe_id) = entry.entry_id.strip_prefix("observe-snapshot-") {
        return ("observe", format!("observe:{observe_id}"));
    }
    if matches!(
        entry.kind.as_str(),
        "tool_invocation"
            | "tool_result"
            | "tool_result_error"
            | "agent_error"
            | "signal_received"
            | "agent_state_change"
            | "file_modification"
            | "agent_session_marker"
    ) && let Some(agent_id) = entry.agent_id.as_deref()
        && let Some((_, sequence)) = entry.entry_id.rsplit_once('-')
    {
        return (
            "conversation",
            format!("conversation:{agent_id}:{sequence}"),
        );
    }
    ("derived", entry.entry_id.clone())
}

pub(super) fn stored_timeline_entry_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<StoredTimelineEntry> {
    Ok(StoredTimelineEntry {
        session_id: row.get(0)?,
        entry_id: row.get(1)?,
        source_kind: row.get(2)?,
        source_key: row.get(3)?,
        recorded_at: row.get(4)?,
        kind: row.get(5)?,
        agent_id: row.get(6)?,
        task_id: row.get(7)?,
        summary: row.get(8)?,
        payload_json: row.get(9)?,
        sort_recorded_at: row.get(10)?,
        sort_tiebreaker: row.get(11)?,
    })
}

#[cfg(test)]
pub(super) fn cursor_from_timeline_entry(entry: &TimelineEntry) -> TimelineCursor {
    TimelineCursor {
        recorded_at: entry.recorded_at.clone(),
        entry_id: entry.entry_id.clone(),
    }
}
