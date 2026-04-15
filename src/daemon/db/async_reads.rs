use sqlx::query_as;

use super::{
    AsyncDaemonDb, CliError, StoredTimelineEntry, TimelineCursor, TimelineEntry,
    TimelineWindowRequest, TimelineWindowResponse, daemon_timeline, db_error, usize_from_i64,
};

const TIMELINE_STATE_SQL: &str = "SELECT revision, entry_count
    FROM session_timeline_state
    WHERE session_id = ?1";
const TIMELINE_CURSOR_OFFSET_SQL: &str = "SELECT
    EXISTS(
        SELECT 1
        FROM session_timeline_entries
        WHERE session_id = ?1
          AND sort_recorded_at = ?2
          AND sort_tiebreaker = ?3
    ) AS cursor_exists,
    (
        SELECT COUNT(*)
        FROM session_timeline_entries
        WHERE session_id = ?1
          AND (
              sort_recorded_at > ?2
              OR (sort_recorded_at = ?2 AND sort_tiebreaker > ?3)
          )
    ) AS cursor_offset";
const TIMELINE_ENTRIES_RANGE_SQL: &str = "SELECT
    session_id,
    entry_id,
    source_kind,
    source_key,
    recorded_at,
    kind,
    agent_id,
    task_id,
    summary,
    payload_json,
    sort_recorded_at,
    sort_tiebreaker
 FROM session_timeline_entries
 WHERE session_id = ?1
 ORDER BY sort_recorded_at DESC, sort_tiebreaker DESC
 LIMIT ?2 OFFSET ?3";
const TIMELINE_CURSOR_AT_OFFSET_SQL: &str = "SELECT
    recorded_at,
    entry_id
 FROM session_timeline_entries
 WHERE session_id = ?1
 ORDER BY sort_recorded_at DESC, sort_tiebreaker DESC
 LIMIT 1 OFFSET ?2";

impl AsyncDaemonDb {
    /// Load a session timeline window from the canonical async timeline ledger.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or payload parse failures.
    pub(crate) async fn load_session_timeline_window(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
    ) -> Result<Option<TimelineWindowResponse>, CliError> {
        let Some(state) = self.load_session_timeline_state(session_id).await? else {
            return Ok(None);
        };
        let payload_scope = timeline_payload_scope(request);
        let entry_count = usize_from_i64(state.entry_count);
        let limit = request.limit.unwrap_or(entry_count).max(1);

        if let Some(response) = self
            .unchanged_timeline_window_response(
                session_id,
                request,
                state.revision,
                entry_count,
                limit,
            )
            .await?
        {
            return Ok(Some(response));
        }

        let window_start = self
            .timeline_window_start(session_id, request, entry_count, limit)
            .await?;
        let entries = self
            .load_timeline_window_entries(
                session_id,
                request,
                entry_count,
                limit,
                window_start,
                payload_scope,
            )
            .await?;
        let window_end = window_start + entries.len();

        Ok(Some(TimelineWindowResponse {
            revision: state.revision,
            total_count: entry_count,
            window_start,
            window_end,
            has_older: window_end < entry_count,
            has_newer: window_start > 0,
            oldest_cursor: entries.last().map(cursor_from_entry),
            newest_cursor: entries.first().map(cursor_from_entry),
            entries: Some(entries),
            unchanged: false,
        }))
    }

    async fn load_session_timeline_state(
        &self,
        session_id: &str,
    ) -> Result<Option<AsyncTimelineStateRow>, CliError> {
        query_as::<_, AsyncTimelineStateRow>(TIMELINE_STATE_SQL)
            .bind(session_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load async session timeline state: {error}")))
    }

    async fn unchanged_timeline_window_response(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
        revision: i64,
        entry_count: usize,
        limit: usize,
    ) -> Result<Option<TimelineWindowResponse>, CliError> {
        if request.known_revision != Some(revision)
            || request.before.is_some()
            || request.after.is_some()
        {
            return Ok(None);
        }

        let latest_window_end = entry_count.min(limit);
        Ok(Some(TimelineWindowResponse {
            revision,
            total_count: entry_count,
            window_start: 0,
            window_end: latest_window_end,
            has_older: latest_window_end < entry_count,
            has_newer: false,
            oldest_cursor: self
                .load_timeline_cursor_at_offset(session_id, latest_window_end.checked_sub(1))
                .await?,
            newest_cursor: self
                .load_timeline_cursor_at_offset(session_id, Some(0))
                .await?,
            entries: None,
            unchanged: true,
        }))
    }

    async fn timeline_window_start(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
        entry_count: usize,
        limit: usize,
    ) -> Result<usize, CliError> {
        if let Some(before) = &request.before {
            return self
                .load_timeline_cursor_offset(session_id, before)
                .await
                .map(|offset| offset.map_or(entry_count, |offset| offset.saturating_add(1)));
        }
        if let Some(after) = &request.after {
            return self
                .load_timeline_cursor_offset(session_id, after)
                .await
                .map(|offset| offset.unwrap_or(0).saturating_sub(limit));
        }
        Ok(0)
    }

    async fn load_timeline_window_entries(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
        entry_count: usize,
        limit: usize,
        window_start: usize,
        payload_scope: daemon_timeline::TimelinePayloadScope,
    ) -> Result<Vec<TimelineEntry>, CliError> {
        if let Some(after) = &request.after {
            let window_end = self
                .load_timeline_cursor_offset(session_id, after)
                .await?
                .unwrap_or(0);
            let window_start = window_end.saturating_sub(limit);
            return self
                .load_timeline_entries_range(
                    session_id,
                    window_start,
                    window_end - window_start,
                    payload_scope,
                )
                .await;
        }

        self.load_timeline_entries_range(
            session_id,
            window_start,
            entry_count.saturating_sub(window_start).min(limit),
            payload_scope,
        )
        .await
    }

    async fn load_timeline_cursor_offset(
        &self,
        session_id: &str,
        cursor: &TimelineCursor,
    ) -> Result<Option<usize>, CliError> {
        let (cursor_exists, cursor_offset) = query_as::<_, (i64, i64)>(TIMELINE_CURSOR_OFFSET_SQL)
            .bind(session_id)
            .bind(&cursor.recorded_at)
            .bind(&cursor.entry_id)
            .fetch_one(self.pool())
            .await
            .map_err(|error| db_error(format!("load async timeline cursor offset: {error}")))?;
        if cursor_exists == 0 {
            return Ok(None);
        }
        Ok(Some(usize_from_i64(cursor_offset)))
    }

    async fn load_timeline_entries_range(
        &self,
        session_id: &str,
        offset: usize,
        limit: usize,
        payload_scope: daemon_timeline::TimelinePayloadScope,
    ) -> Result<Vec<TimelineEntry>, CliError> {
        if limit == 0 {
            return Ok(Vec::new());
        }

        let rows = query_as::<_, AsyncStoredTimelineEntryRow>(TIMELINE_ENTRIES_RANGE_SQL)
            .bind(session_id)
            .bind(i64::try_from(limit).unwrap_or(i64::MAX))
            .bind(i64::try_from(offset).unwrap_or(i64::MAX))
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("query async timeline range: {error}")))?;

        rows.into_iter()
            .map(|row| row.into_stored_entry().into_timeline_entry(payload_scope))
            .collect()
    }

    async fn load_timeline_cursor_at_offset(
        &self,
        session_id: &str,
        offset: Option<usize>,
    ) -> Result<Option<TimelineCursor>, CliError> {
        let Some(offset) = offset else {
            return Ok(None);
        };

        query_as::<_, AsyncTimelineCursorRow>(TIMELINE_CURSOR_AT_OFFSET_SQL)
            .bind(session_id)
            .bind(i64::try_from(offset).unwrap_or(i64::MAX))
            .fetch_optional(self.pool())
            .await
            .map(|row| row.map(AsyncTimelineCursorRow::into_cursor))
            .map_err(|error| db_error(format!("load async timeline cursor at offset: {error}")))
    }
}

#[derive(sqlx::FromRow)]
struct AsyncTimelineStateRow {
    revision: i64,
    entry_count: i64,
}

#[derive(sqlx::FromRow)]
struct AsyncStoredTimelineEntryRow {
    session_id: String,
    entry_id: String,
    source_kind: String,
    source_key: String,
    recorded_at: String,
    kind: String,
    agent_id: Option<String>,
    task_id: Option<String>,
    summary: String,
    payload_json: String,
    sort_recorded_at: String,
    sort_tiebreaker: String,
}

impl AsyncStoredTimelineEntryRow {
    fn into_stored_entry(self) -> StoredTimelineEntry {
        StoredTimelineEntry {
            session_id: self.session_id,
            entry_id: self.entry_id,
            source_kind: self.source_kind,
            source_key: self.source_key,
            recorded_at: self.recorded_at,
            kind: self.kind,
            agent_id: self.agent_id,
            task_id: self.task_id,
            summary: self.summary,
            payload_json: self.payload_json,
            sort_recorded_at: self.sort_recorded_at,
            sort_tiebreaker: self.sort_tiebreaker,
        }
    }
}

#[derive(sqlx::FromRow)]
struct AsyncTimelineCursorRow {
    recorded_at: String,
    entry_id: String,
}

impl AsyncTimelineCursorRow {
    fn into_cursor(self) -> TimelineCursor {
        TimelineCursor {
            recorded_at: self.recorded_at,
            entry_id: self.entry_id,
        }
    }
}

fn timeline_payload_scope(
    request: &TimelineWindowRequest,
) -> daemon_timeline::TimelinePayloadScope {
    match request.scope.as_deref() {
        Some("summary") => daemon_timeline::TimelinePayloadScope::Summary,
        _ => daemon_timeline::TimelinePayloadScope::Full,
    }
}

fn cursor_from_entry(entry: &TimelineEntry) -> TimelineCursor {
    TimelineCursor {
        recorded_at: entry.recorded_at.clone(),
        entry_id: entry.entry_id.clone(),
    }
}
