use rusqlite::Connection;

use super::CliError;

const INTENT_RECOVERY_INDEX_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0082_daemon_v71_task_board_intent_recovery_index.sql"
);

/// Index the exact dispatch identity used by bounded startup recovery.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(INTENT_RECOVERY_INDEX_SQL)
        .map_err(|error| super::db_error(format!("index dispatch intent recovery: {error}")))
}

#[cfg(test)]
#[path = "schema_v71_tests.rs"]
mod tests;
