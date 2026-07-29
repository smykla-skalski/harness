use rusqlite::Connection;

use super::{CliError, db_error};

const HELD_DISPATCH_DDL: &str = include_str!("migrations/0027_daemon_v33_held_dispatch.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if !table_exists(conn, "task_board_dispatch_intents")? {
        return stamp_schema_version(conn);
    }
    if dispatch_intents_support_held(conn)? {
        return stamp_schema_version(conn);
    }
    conn.execute_batch(HELD_DISPATCH_DDL)
        .map_err(|error| db_error(format!("apply held dispatch schema v33: {error}")))
}

fn dispatch_intents_support_held(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master
         WHERE type = 'table' AND name = 'task_board_dispatch_intents'",
        [],
        |row| row.get::<_, String>(0),
    )
    .map(|sql| sql.contains("'held'"))
    .map_err(|error| db_error(format!("read task-board dispatch intent schema: {error}")))
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
