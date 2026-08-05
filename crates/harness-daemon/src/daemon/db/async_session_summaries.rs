use sqlx::query_as;

use super::summary_rows::AsyncSessionSummaryRow;
use super::{
    AsyncDaemonDb, AsyncResolvedSessionRow, CliError, daemon_index, daemon_protocol, db_error,
    trace_async_db_operation,
};
use crate::session::storage;
use crate::telemetry::record_daemon_db_pool_state;

const SESSION_SUMMARIES_SQL: &str = "SELECT
    s.session_id,
    s.title,
    s.context,
    s.status,
    s.created_at,
    s.updated_at,
    s.last_activity_at,
    s.leader_id,
    s.observe_id,
    s.pending_leader_transfer AS pending_leader_transfer_json,
    s.metrics_json,
    s.state_json,
    s.archived_at,
    p.project_id,
    p.name AS project_name,
    p.project_dir,
    p.repository_root,
    p.context_root,
    p.checkout_id,
    p.checkout_name,
    p.is_worktree,
    p.worktree_name
 FROM sessions s
 JOIN projects p ON p.project_id = s.project_id
 WHERE (
    s.archived_at IS NULL OR (
      s.status = 'ended'
      AND COALESCE(json_extract(s.state_json, '$.schema_version'), 0) < 13
    )
 )
 ORDER BY s.updated_at DESC";
const RESOLVE_SESSION_SQL: &str = "SELECT
    s.state_json,
    p.project_id,
    p.name AS project_name,
    p.project_dir,
    p.repository_root,
    p.checkout_id,
    p.checkout_name,
    p.context_root,
    p.is_worktree,
    p.worktree_name
 FROM sessions s
 JOIN projects p ON p.project_id = s.project_id
 WHERE s.session_id = ?1
   AND (
     s.archived_at IS NULL OR (
       s.status = 'ended'
       AND COALESCE(json_extract(s.state_json, '$.schema_version'), 0) < 13
     )
   )";

/// Session summary and resolution reads that canonicalize a legacy-shaped
/// row via [`AsyncSessionWriteQueries::save_session_state`](super::AsyncSessionWriteQueries::save_session_state)
/// when one turns up, so this stays a `db`-external extension trait rather
/// than an inherent [`AsyncDaemonDb`] method the way the rest of the pool's
/// clean read paths do.
pub(crate) trait AsyncSessionSummaryQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    async fn list_session_summaries(
        &self,
    ) -> Result<Vec<daemon_protocol::SessionSummary>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    async fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<daemon_index::ResolvedSession>, CliError>;
}

impl AsyncSessionSummaryQueries for AsyncDaemonDb {
    async fn list_session_summaries(
        &self,
    ) -> Result<Vec<daemon_protocol::SessionSummary>, CliError> {
        trace_async_db_operation(
            "list_session_summaries",
            "read",
            Some(self.storage_path()),
            || async {
                record_daemon_db_pool_state(
                    "async",
                    u64::from(self.pool().size()),
                    u64::try_from(self.pool().num_idle()).unwrap_or(u64::MAX),
                );
                let rows = query_as::<_, AsyncSessionSummaryRow>(SESSION_SUMMARIES_SQL)
                    .fetch_all(self.pool())
                    .await
                    .map_err(|error| db_error(format!("query async session summaries: {error}")))?;

                let mut summaries = Vec::new();
                for row in rows {
                    if !storage::is_valid_session_id(&row.session_id) {
                        continue;
                    }
                    summaries.push(row.into_summary(self).await?);
                }
                Ok(summaries)
            },
        )
        .await
    }

    async fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<daemon_index::ResolvedSession>, CliError> {
        storage::validate_session_id(session_id)?;
        trace_async_db_operation(
            "resolve_session",
            "read",
            Some(self.storage_path()),
            || async {
                record_daemon_db_pool_state(
                    "async",
                    u64::from(self.pool().size()),
                    u64::try_from(self.pool().num_idle()).unwrap_or(u64::MAX),
                );
                let row = query_as::<_, AsyncResolvedSessionRow>(RESOLVE_SESSION_SQL)
                    .bind(session_id)
                    .fetch_optional(self.pool())
                    .await
                    .map_err(|error| {
                        db_error(format!("resolve async session {session_id}: {error}"))
                    })?;
                match row {
                    Some(row) => row.into_resolved_session(self).await.map(Some),
                    None => Ok(None),
                }
            },
        )
        .await
    }
}
