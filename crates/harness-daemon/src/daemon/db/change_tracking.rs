//! Sync mirror of `async_change_tracking.rs`'s `load_change_tracking_since`.
//! The watch loop's sync path used to run this same query inline against
//! `DaemonDb::connection()` instead of through a named method; giving it one
//! here is what lets `watch::storage::ChangeTrackingSyncQueries` reach it
//! through a trait instead of raw SQL in the caller.
//!
//! `LOAD_CHANGE_TRACKING_SQL` lives here rather than duplicated in both
//! modules; `async_change_tracking.rs` imports it so the sync and async
//! backends can never drift onto two different query texts.

use super::{CliError, DaemonDb, db_error};

pub(crate) const LOAD_CHANGE_TRACKING_SQL: &str = "SELECT scope, change_seq
     FROM change_tracking
     WHERE change_seq > ?1
     ORDER BY change_seq";

/// The sync side of the canonical change-tracking read.
pub(crate) trait ChangeTrackingQueries {
    /// Load canonical change-tracking rows newer than the provided sequence.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError>;
}

impl ChangeTrackingQueries for DaemonDb {
    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        let rows = self
            .conn
            .prepare_cached(LOAD_CHANGE_TRACKING_SQL)
            .and_then(|mut statement| {
                statement
                    .query_map([last_change_seq], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                    })
                    .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
            })
            .map_err(|error| db_error(format!("query change tracking: {error}")))?;
        Ok(rows)
    }
}
