use rusqlite::Connection;

use super::CliError;

const PROGRESS_RECOVERY_INDEX_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0081_daemon_v70_task_board_progress_recovery_index.sql"
);

/// Index unfinished worker progress for bounded daemon-start recovery.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(PROGRESS_RECOVERY_INDEX_SQL)
        .map_err(|error| super::db_error(format!("index work-item recovery progress: {error}")))
}

#[cfg(test)]
#[path = "schema_v70_tests.rs"]
mod tests;
