use super::{DaemonDb, CliError, db_error, daemon_launchd, daemon_state};

impl DaemonDb {
    /// Set a diagnostics cache entry by key.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn set_diagnostics_cache(&self, key: &str, value: &str) -> Result<(), CliError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO diagnostics_cache (key, value) VALUES (?1, ?2)",
                rusqlite::params![key, value],
            )
            .map_err(|error| db_error(format!("set diagnostics cache: {error}")))?;
        Ok(())
    }

    /// Load a diagnostics cache entry.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn get_diagnostics_cache(&self, key: &str) -> Result<Option<String>, CliError> {
        match self.conn.query_row(
            "SELECT value FROM diagnostics_cache WHERE key = ?1",
            [key],
            |row| row.get(0),
        ) {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("get diagnostics cache: {error}"))),
        }
    }

    /// Cache the launch agent status and workspace diagnostics at daemon startup.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn cache_startup_diagnostics(&self) -> Result<(), CliError> {
        let launch_agent = daemon_launchd::launch_agent_status();
        let launch_agent_json = serde_json::to_string(&launch_agent).unwrap_or_default();
        self.set_diagnostics_cache("launch_agent", &launch_agent_json)?;

        let workspace = daemon_state::diagnostics()?;
        let workspace_json = serde_json::to_string(&workspace).unwrap_or_default();
        self.set_diagnostics_cache("workspace", &workspace_json)?;

        Ok(())
    }

    /// Load cached launch agent status.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn load_cached_launch_agent_status(
        &self,
    ) -> Result<Option<daemon_launchd::LaunchAgentStatus>, CliError> {
        let json = self.get_diagnostics_cache("launch_agent")?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Load cached workspace diagnostics.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn load_cached_workspace_diagnostics(
        &self,
    ) -> Result<Option<daemon_state::DaemonDiagnostics>, CliError> {
        let json = self.get_diagnostics_cache("workspace")?;
        Ok(json.and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Load recent daemon events, ordered by most recent first.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_recent_daemon_events(
        &self,
        limit: u32,
    ) -> Result<Vec<daemon_state::DaemonAuditEvent>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT recorded_at, level, message FROM daemon_events
                 ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|error| db_error(format!("prepare daemon events: {error}")))?;

        let rows = statement
            .query_map([i64::from(limit)], |row| {
                Ok(daemon_state::DaemonAuditEvent {
                    recorded_at: row.get(0)?,
                    level: row.get(1)?,
                    message: row.get(2)?,
                })
            })
            .map_err(|error| db_error(format!("query daemon events: {error}")))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read event row: {error}")))
    }
}

pub(super) fn import_daemon_events(db: &DaemonDb) -> Result<(), CliError> {
    let events = daemon_state::read_recent_events(1000)?;
    for event in &events {
        db.conn
            .execute(
                "INSERT OR IGNORE INTO daemon_events (recorded_at, level, message)
                 VALUES (?1, ?2, ?3)",
                rusqlite::params![event.recorded_at, event.level, event.message],
            )
            .map_err(|error| db_error(format!("import daemon event: {error}")))?;
    }
    Ok(())
}
