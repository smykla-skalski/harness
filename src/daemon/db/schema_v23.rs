use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if enforcement_snapshot_column_exists(conn)? {
        conn.execute(
            "ALTER TABLE policy_workspace DROP COLUMN enforcement_snapshot_json",
            [],
        )
        .map_err(|error| db_error(format!("drop policy enforcement snapshot column: {error}")))?;
    }
    stamp_schema_version(conn)
}

fn enforcement_snapshot_column_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('policy_workspace') \
         WHERE name = 'enforcement_snapshot_json'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check policy enforcement snapshot column: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '23' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v23: {error}")))
}
