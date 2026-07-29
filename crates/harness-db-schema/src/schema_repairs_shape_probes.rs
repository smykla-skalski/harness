//! Small `sqlite_master`/`pragma_*` existence checks shared by
//! [`super::schema_repairs`]'s shape-drift detection. Split out on its own
//! only to keep `schema_repairs.rs` under the repo's line-count limit; every
//! function here is a direct, unmodified move.

use super::{CliError, Connection, db_error};

pub(super) fn table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name} table existence: {error}")))
}

pub(super) fn index_exists(conn: &Connection, index_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
        [index_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {index_name} index existence: {error}")))
}

pub(super) fn trigger_exists(conn: &Connection, trigger_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
        [trigger_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {trigger_name} trigger existence: {error}")))
}

pub(super) fn table_sql_contains(
    conn: &Connection,
    table_name: &str,
    expected: &str,
) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, String>(0),
    )
    .map(|sql| sql.contains(expected))
    .map_err(|error| db_error(format!("read {table_name} table definition: {error}")))
}

pub(super) fn column_exists(
    conn: &Connection,
    table_name: &str,
    column_name: &str,
) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table_name, column_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name}.{column_name}: {error}")))
}
