use rusqlite::Connection;

use super::CliError;

const WORK_ITEM_PROGRESS_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0080_daemon_v69_task_board_work_item_progress.sql"
);

/// Add durable worker progress and checkpoints for dispatched work items.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(WORK_ITEM_PROGRESS_SQL)
        .map_err(|error| super::db_error(format!("add task-board work item progress: {error}")))
}

#[cfg(test)]
#[path = "schema_v69_tests.rs"]
mod tests;
