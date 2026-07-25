use rusqlite::Connection;

use super::CliError;

const SHAPE_COLUMN_SQL: &str = include_str!("migrations/0050_daemon_v53_task_board_project_shape.sql");
pub(super) const SHAPE_BACKFILL_SQL: &str =
    include_str!("migrations/0051_daemon_v53_task_board_project_shape_backfill.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    // Same split as v52: `ADD COLUMN` has no `IF NOT EXISTS` and the repair
    // chain replays every step, so the ALTER asks first while the backfill
    // below is safe to repeat and carries the version stamp.
    if !column_exists(conn, "task_board_projects", "shape")? {
        conn.execute_batch(SHAPE_COLUMN_SQL)
            .map_err(|error| super::db_error(format!("apply schema v53 project shape: {error}")))?;
    }
    conn.execute_batch(SHAPE_BACKFILL_SQL)
        .map_err(|error| super::db_error(format!("backfill schema v53 project shape: {error}")))
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
#[path = "schema_v53_tests.rs"]
mod tests;
