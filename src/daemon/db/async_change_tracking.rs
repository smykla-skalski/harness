use sqlx::query_as;

use super::{AsyncDaemonDb, CliError, db_error};

const LOAD_CHANGE_TRACKING_SQL: &str = "SELECT scope, change_seq
     FROM change_tracking
     WHERE change_seq > ?1
     ORDER BY change_seq";

impl AsyncDaemonDb {
    /// Load canonical change-tracking rows newer than the provided sequence.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn load_change_tracking_since(
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
