use rusqlite::Connection;

use super::{CliError, db_error};

/// Policy-canvas kill-switch snapshot persistence (schema v16).
const POLICY_ENFORCEMENT_SNAPSHOT_DDL: &str =
    include_str!("migrations/0010_daemon_v16_policy_enforcement_snapshot.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('policy_workspace') \
             WHERE name = 'enforcement_snapshot_json'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '16' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v16: {error}")));
    }
    conn.execute_batch(POLICY_ENFORCEMENT_SNAPSHOT_DDL)
        .map_err(|error| db_error(format!("migrate v15 -> v16 policy snapshot: {error}")))
}
