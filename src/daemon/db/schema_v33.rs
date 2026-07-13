use rusqlite::Connection;

use super::{CliError, db_error};

const HELD_DISPATCH_DDL: &str = include_str!("migrations/0027_daemon_v33_held_dispatch.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if !table_exists(conn, "task_board_dispatch_intents")? {
        return stamp_schema_version(conn);
    }
    conn.execute_batch(HELD_DISPATCH_DDL)
        .map_err(|error| db_error(format!("apply held dispatch schema v33: {error}")))
}

fn table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check table {table_name}: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '33' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v33: {error}")))
}
