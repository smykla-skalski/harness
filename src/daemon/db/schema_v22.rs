use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "global_policy_enforcement_enabled",
        "ALTER TABLE policy_workspace
         ADD COLUMN global_policy_enforcement_enabled INTEGER NOT NULL DEFAULT 1
             CHECK (global_policy_enforcement_enabled IN (0, 1))",
    )?;
    stamp_schema_version(conn)
}

fn add_column_if_missing(conn: &Connection, column_name: &str, sql: &str) -> Result<(), CliError> {
    match conn.execute(sql, []) {
        Ok(_) => Ok(()),
        Err(_) if column_exists(conn, "policy_workspace", column_name)? => Ok(()),
        Err(error) => Err(db_error(format!(
            "add v22 policy workspace column {column_name}: {error}"
        ))),
    }
}

fn column_exists(conn: &Connection, table_name: &str, column_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table_name, column_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name}.{column_name}: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '22' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v22: {error}")))
}
