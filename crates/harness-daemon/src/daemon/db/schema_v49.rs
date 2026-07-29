use rusqlite::Connection;

use super::CliError;

const MIGRATION_SQL: &str =
    include_str!("migrations/0043_daemon_v49_task_board_triage_escalation.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(MIGRATION_SQL)
        .map_err(|error| super::db_error(format!("apply schema v49: {error}")))
}

#[cfg(test)]
#[path = "schema_v49_tests.rs"]
mod tests;
