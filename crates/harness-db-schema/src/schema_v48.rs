use rusqlite::Connection;

use super::CliError;

const MIGRATION_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0042_daemon_v48_task_board_triage_rules.sql"
);

/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(MIGRATION_SQL)
        .map_err(|error| super::db_error(format!("apply schema v48: {error}")))
}

#[cfg(test)]
#[path = "schema_v48_tests.rs"]
mod tests;
