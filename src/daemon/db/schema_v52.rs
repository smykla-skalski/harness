use rusqlite::Connection;

use super::CliError;

const COLOR_COLUMN_SQL: &str = include_str!("migrations/0048_daemon_v52_task_board_project_color.sql");
pub(super) const COLOR_BACKFILL_SQL: &str =
    include_str!("migrations/0049_daemon_v52_task_board_project_color_backfill.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    // `ADD COLUMN` has no `IF NOT EXISTS` and the repair chain replays every
    // step, so this half is the one that needs asking first. The backfill below
    // is safe to repeat and carries the version stamp, which is why it sits in
    // its own file rather than after the ALTER.
    if !column_exists(conn, "task_board_projects", "color")? {
        conn.execute_batch(COLOR_COLUMN_SQL)
            .map_err(|error| super::db_error(format!("apply schema v52 project color: {error}")))?;
    }
    conn.execute_batch(COLOR_BACKFILL_SQL)
        .map_err(|error| super::db_error(format!("backfill schema v52 project color: {error}")))
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table, column],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| super::db_error(format!("check {table}.{column}: {error}")))
}

#[cfg(test)]
#[path = "schema_v52_tests.rs"]
mod tests;
