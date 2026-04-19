use sqlx::query_as;

use super::{AsyncDaemonDb, CliError, db_error};

/// Resolve a runtime-session ID to live agents.
///
/// Uses the compound index `idx_agents_runtime_session(runtime,
/// agent_session_id)` directly for the primary branch (agent has an explicit
/// runtime-session ID) and falls through to the legacy fallback branch when
/// the agent inherited the orchestration session ID. Restricted to active
/// sessions and alive agents (`status IN ('active', 'idle')`) so dead rows
/// do not pollute the resolution.
const RESOLVE_RUNTIME_SESSION_AGENT_SQL: &str = "SELECT a.session_id, a.agent_id
    FROM agents a
    INNER JOIN sessions s ON s.session_id = a.session_id
    WHERE a.runtime = ?1
      AND (
          a.agent_session_id = ?2
          OR (a.agent_session_id IS NULL AND a.session_id = ?2)
      )
      AND a.status IN ('active', 'idle')
      AND s.is_active = 1
    ORDER BY a.session_id, a.agent_id";

impl AsyncDaemonDb {
    /// Resolve a runtime-session ID to live (`session_id`, `agent_id`) pairs.
    ///
    /// Returns every match so the caller can detect ambiguity. Uses the
    /// compound index on `agents(runtime, agent_session_id)` and restricts
    /// the result to alive agents inside active sessions.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn resolve_runtime_session_agents(
        &self,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<Vec<(String, String)>, CliError> {
        let rows = query_as::<_, AsyncRuntimeSessionAgentRow>(RESOLVE_RUNTIME_SESSION_AGENT_SQL)
            .bind(runtime_name)
            .bind(runtime_session_id)
            .fetch_all(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "resolve runtime session agents for runtime '{runtime_name}' \
                     session '{runtime_session_id}': {error}"
                ))
            })?;
        Ok(rows
            .into_iter()
            .map(|row| (row.session_id, row.agent_id))
            .collect())
    }
}

#[derive(sqlx::FromRow)]
struct AsyncRuntimeSessionAgentRow {
    session_id: String,
    agent_id: String,
}
