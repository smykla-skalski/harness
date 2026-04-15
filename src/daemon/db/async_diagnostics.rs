use sqlx::{query_as, query_scalar};

use super::{AsyncDaemonDb, CliError, daemon_launchd, daemon_state, db_error};

const DIAGNOSTICS_CACHE_SQL: &str = "SELECT value FROM diagnostics_cache WHERE key = ?1";
const RECENT_DAEMON_EVENTS_SQL: &str = "
SELECT recorded_at, level, message
FROM daemon_events
ORDER BY id DESC
LIMIT ?1";

impl AsyncDaemonDb {
    async fn load_diagnostics_cache(&self, key: &str) -> Result<Option<String>, CliError> {
        query_scalar::<_, String>(DIAGNOSTICS_CACHE_SQL)
            .bind(key)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("read async diagnostics cache {key}: {error}")))
    }

    /// Load cached launch agent status from the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub(crate) async fn load_cached_launch_agent_status(
        &self,
    ) -> Result<Option<daemon_launchd::LaunchAgentStatus>, CliError> {
        let json = self.load_diagnostics_cache("launch_agent").await?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Load cached workspace diagnostics from the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub(crate) async fn load_cached_workspace_diagnostics(
        &self,
    ) -> Result<Option<daemon_state::DaemonDiagnostics>, CliError> {
        let json = self.load_diagnostics_cache("workspace").await?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Load recent daemon audit events from the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub(crate) async fn load_recent_daemon_events(
        &self,
        limit: u32,
    ) -> Result<Vec<daemon_state::DaemonAuditEvent>, CliError> {
        let rows = query_as::<_, (String, String, String)>(RECENT_DAEMON_EVENTS_SQL)
            .bind(i64::from(limit))
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("query async daemon events: {error}")))?;
        Ok(rows
            .into_iter()
            .map(
                |(recorded_at, level, message)| daemon_state::DaemonAuditEvent {
                    recorded_at,
                    level,
                    message,
                },
            )
            .collect())
    }
}
