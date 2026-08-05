//! `DaemonDbTimeline`'s pure `StoredTimelineEntry` construction helpers moved
//! to `harness-daemon-db-queries` (see that crate's `timeline` module) - the
//! trait itself stays here, since `rebuild_session_timeline_from_resolved`
//! constructs `db_timeline_source::DaemonDbTimelineHandle`, a
//! `harness-daemon`-local wrapper that also needs `session_data::SessionCoreQueries`
//! (not yet extracted). That coupling keeps the whole trait local for now
//! rather than splitting it further.

use harness_daemon_db_queries::stored_timeline_entry_for_rebuild;
#[cfg(test)]
use harness_daemon_db_queries::{
    SessionTimelineStateRow, cursor_from_timeline_entry, stored_timeline_entry_from_row,
};
#[cfg(test)]
use harness_protocol::timeline::{TimelineCursor, TimelineWindowRequest, TimelineWindowResponse};
#[cfg(test)]
use rusqlite::OptionalExtension;

#[cfg(test)]
use super::StoredTimelineEntry;
#[cfg(test)]
use super::usize_from_i64;
use super::{
    CliError, DaemonDb, daemon_index, daemon_timeline, db_error,
    replace_all_session_timeline_entries,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db_timeline_source::DaemonDbTimelineHandle;

pub(crate) trait DaemonDbTimeline {
    #[cfg(test)]
    fn load_session_timeline_window(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
    ) -> Result<Option<TimelineWindowResponse>, CliError>;

    /// Rebuild the canonical timeline ledger from the current resolved session.
    ///
    /// # Errors
    /// Returns [`CliError`] when timeline materialization or SQL writes fail.
    fn rebuild_session_timeline_from_resolved(
        &self,
        resolved: &daemon_index::ResolvedSession,
    ) -> Result<(), CliError>;

    /// Rebuild the timeline ledger for every session by replaying legacy sources
    /// (`session_log`, `conversation_events`, `task_checkpoints`, `signal_index`).
    ///
    /// Sessions whose state cannot be parsed are logged and skipped - failing the
    /// whole backfill because of one bad row would block the migration.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session list cannot be enumerated.
    fn backfill_legacy_timelines(&self) -> Result<(), CliError>;

    fn list_backfillable_session_ids(&self) -> Result<Vec<String>, CliError>;

    fn backfill_session_timeline(&self, session_id: &str);

    #[cfg(test)]
    fn load_session_timeline_state(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionTimelineStateRow>, CliError>;

    #[cfg(test)]
    fn load_timeline_cursor_offset(
        &self,
        session_id: &str,
        cursor: &TimelineCursor,
    ) -> Result<Option<usize>, CliError>;

    #[cfg(test)]
    fn load_timeline_entries_range(
        &self,
        session_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<StoredTimelineEntry>, CliError>;

    #[cfg(test)]
    fn load_timeline_cursor_at_offset(
        &self,
        session_id: &str,
        offset: Option<usize>,
    ) -> Result<Option<TimelineCursor>, CliError>;
}

impl DaemonDbTimeline for DaemonDb {
    #[cfg(test)]
    fn load_session_timeline_window(
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

    fn rebuild_session_timeline_from_resolved(
        &self,
        resolved: &daemon_index::ResolvedSession,
    ) -> Result<(), CliError> {
        let entries = daemon_timeline::session_timeline_from_resolved_with_db_scope(
            resolved,
            &DaemonDbTimelineHandle(self),
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

    fn backfill_legacy_timelines(&self) -> Result<(), CliError> {
        for session_id in self.list_backfillable_session_ids()? {
            self.backfill_session_timeline(&session_id);
        }
        Ok(())
    }

    fn list_backfillable_session_ids(&self) -> Result<Vec<String>, CliError> {
        let mut statement = self
            .conn
            .prepare("SELECT session_id FROM sessions")
            .map_err(|error| db_error(format!("prepare backfill session list: {error}")))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| db_error(format!("query backfill session list: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read backfill session list: {error}")))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn backfill_session_timeline(&self, session_id: &str) {
        let resolved = match self.resolve_session(session_id) {
            Ok(Some(resolved)) => resolved,
            Ok(None) => {
                tracing::warn!(
                    session_id = %session_id,
                    "timeline backfill skipped: session could not be resolved"
                );
                return;
            }
            Err(error) => {
                tracing::warn!(
                    session_id = %session_id,
                    %error,
                    "timeline backfill skipped: session state could not be parsed"
                );
                return;
            }
        };
        if let Err(error) = self.rebuild_session_timeline_from_resolved(&resolved) {
            tracing::warn!(
                session_id = %session_id,
                %error,
                "timeline backfill failed for session; leaving ledger empty"
            );
        }
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
