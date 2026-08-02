use sqlx::query_as;

use super::change_tracking::LOAD_CHANGE_TRACKING_SQL;
use super::{AsyncDaemonDb, CliError, db_error};

const CURRENT_CHANGE_SEQ_SQL: &str =
    "SELECT last_seq FROM change_tracking_state WHERE singleton = 1";

/// Async mirror of `change_tracking::ChangeTrackingQueries`, plus the
/// current-sequence read, through the canonical async daemon DB.
pub(crate) trait AsyncChangeTrackingQueries: Send + Sync {
    /// Read the current global change sequence (the singleton `last_seq`).
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    async fn current_change_sequence(&self) -> Result<i64, CliError>;

    /// Load canonical change-tracking rows newer than the provided sequence.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    async fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError>;
}

impl AsyncChangeTrackingQueries for AsyncDaemonDb {
    async fn current_change_sequence(&self) -> Result<i64, CliError> {
        let row: (i64,) = query_as(CURRENT_CHANGE_SEQ_SQL)
            .fetch_one(self.pool())
            .await
            .map_err(|error| db_error(format!("read current async change sequence: {error}")))?;
        Ok(row.0)
    }

    async fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        let rows = query_as::<_, AsyncChangeTrackingRow>(LOAD_CHANGE_TRACKING_SQL)
            .bind(last_change_seq)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("query async change tracking: {error}")))?;
        Ok(rows
            .into_iter()
            .map(|row| (row.scope, row.change_seq))
            .collect())
    }
}

#[derive(sqlx::FromRow)]
struct AsyncChangeTrackingRow {
    scope: String,
    change_seq: i64,
}
