use rusqlite::Connection;

use super::{CliError, db_error};

const POLICY_DECISIONS_DDL: &str = include_str!("migrations/0018_daemon_v24_policy_decisions.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='policy_decisions'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '24' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v24: {error}")));
    }
    conn.execute_batch(POLICY_DECISIONS_DDL)
        .map_err(|error| db_error(format!("migrate v23 -> v24 policy decisions: {error}")))
}
