use rusqlite::Connection;

use super::{CliError, db_error};

/// Historical v16 migration. The active code no longer reads this column, but
/// the `SQLx` migration identity must stay stable for existing local databases.
const POLICY_ENFORCEMENT_SNAPSHOT_DDL: &str =
    include_str!("migrations/0010_daemon_v16_policy_enforcement_snapshot.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if enforcement_snapshot_column_exists(conn)? {
        return stamp_schema_version(conn);
    }
    match conn.execute_batch(POLICY_ENFORCEMENT_SNAPSHOT_DDL) {
        Ok(()) => Ok(()),
        Err(_) if enforcement_snapshot_column_exists(conn)? => stamp_schema_version(conn),
        Err(error) => Err(db_error(format!(
            "migrate v15 -> v16 policy snapshot: {error}"
        ))),
    }
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
        "UPDATE schema_meta SET value = '16' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v16: {error}")))
}
