use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_daemon_launchd as daemon_launchd;
use harness_daemon_root as daemon_state;
use harness_kernel::errors::CliError;
use sqlx::{query, query_as, query_scalar};

const DIAGNOSTICS_CACHE_SQL: &str = "SELECT value FROM diagnostics_cache WHERE key = ?1";
const UPSERT_DIAGNOSTICS_CACHE_SQL: &str =
    "INSERT OR REPLACE INTO diagnostics_cache (key, value) VALUES (?1, ?2)";
const RECENT_DAEMON_EVENTS_SQL: &str = "
SELECT recorded_at, level, message
FROM daemon_events
ORDER BY id DESC
LIMIT ?1";

/// Async mirror of `diagnostics::DaemonDbDiagnostics`, through the canonical
/// async daemon DB.
pub trait AsyncDiagnosticsQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on write failure.
    fn set_diagnostics_cache(
        &self,
        key: &str,
        value: &str,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on write failure.
    fn cache_startup_diagnostics(&self) -> impl Future<Output = Result<(), CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_cached_launch_agent_status(
        &self,
    ) -> impl Future<Output = Result<Option<daemon_launchd::LaunchAgentStatus>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_cached_workspace_diagnostics(
        &self,
    ) -> impl Future<Output = Result<Option<daemon_state::DaemonDiagnostics>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on query failure.
    fn load_recent_daemon_events(
        &self,
        limit: u32,
    ) -> impl Future<Output = Result<Vec<daemon_state::DaemonAuditEvent>, CliError>> + Send;
}

impl AsyncDiagnosticsQueries for AsyncDaemonDb {
    async fn set_diagnostics_cache(&self, key: &str, value: &str) -> Result<(), CliError> {
        query(UPSERT_DIAGNOSTICS_CACHE_SQL)
            .bind(key)
            .bind(value)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("write async diagnostics cache {key}: {error}")))?;
        Ok(())
    }

    async fn cache_startup_diagnostics(&self) -> Result<(), CliError> {
        let launch_agent = daemon_launchd::launch_agent_status();
        let launch_agent_json = serde_json::to_string(&launch_agent).unwrap_or_default();
        self.set_diagnostics_cache("launch_agent", &launch_agent_json)
            .await?;

        let workspace = daemon_state::diagnostics()?;
        let workspace_json = serde_json::to_string(&workspace).unwrap_or_default();
        self.set_diagnostics_cache("workspace", &workspace_json)
            .await
    }

    async fn load_cached_launch_agent_status(
        &self,
    ) -> Result<Option<daemon_launchd::LaunchAgentStatus>, CliError> {
        let json = load_diagnostics_cache(self, "launch_agent").await?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    async fn load_cached_workspace_diagnostics(
        &self,
    ) -> Result<Option<daemon_state::DaemonDiagnostics>, CliError> {
        let json = load_diagnostics_cache(self, "workspace").await?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    async fn load_recent_daemon_events(
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

async fn load_diagnostics_cache(db: &AsyncDaemonDb, key: &str) -> Result<Option<String>, CliError> {
    query_scalar::<_, String>(DIAGNOSTICS_CACHE_SQL)
        .bind(key)
        .fetch_optional(db.pool())
        .await
        .map_err(|error| db_error(format!("read async diagnostics cache {key}: {error}")))
}
