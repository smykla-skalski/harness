use rusqlite::Connection;

use super::CliError;

const PROJECTS_SQL: &str = include_str!("migrations/0045_daemon_v51_task_board_projects.sql");
const ATTRIBUTION_SQL: &str =
    include_str!("migrations/0046_daemon_v51_task_board_item_attribution.sql");
const ATTRIBUTION_INDEX_SQL: &str =
    include_str!("migrations/0047_daemon_v51_task_board_item_attribution_index.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(PROJECTS_SQL)
        .map_err(|error| super::db_error(format!("apply schema v51 projects: {error}")))?;
    // The repair chain replays every step unconditionally and ADD COLUMN has no
    // IF NOT EXISTS, so the attribution half runs once and later passes the
    // index-only path. The backfill rides along with it: once the column
    // exists, every write path keeps it current. The index is rebuilt either
    // way, because a database that lost it would otherwise never get it back.
    if column_exists(conn, "task_board_items", "source_project_id")? {
        return conn
            .execute_batch(ATTRIBUTION_INDEX_SQL)
            .map_err(|error| super::db_error(format!("stamp schema v51: {error}")));
    }
    // The column and its backfill have to land together. `execute_batch`
    // autocommits statement by statement, so a crash after the ALTER would
    // leave the column in place and send the next boot down the stamp-only
    // path above, stranding every existing item unattributed for good.
    let transaction = conn
        .unchecked_transaction()
        .map_err(|error| super::db_error(format!("begin schema v51 attribution: {error}")))?;
    transaction
        .execute_batch(ATTRIBUTION_SQL)
        .map_err(|error| super::db_error(format!("apply schema v51 attribution: {error}")))?;
    transaction
        .commit()
        .map_err(|error| super::db_error(format!("commit schema v51 attribution: {error}")))?;
    conn.execute_batch(ATTRIBUTION_INDEX_SQL)
        .map_err(|error| super::db_error(format!("index schema v51 attribution: {error}")))
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
#[path = "schema_v51_tests.rs"]
mod tests;
