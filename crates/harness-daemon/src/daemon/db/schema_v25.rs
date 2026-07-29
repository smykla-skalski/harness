use rusqlite::Connection;

use super::{CliError, db_error};

const POLICY_SCENARIOS_DDL: &str = include_str!("migrations/0019_daemon_v25_policy_scenarios.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('policy_workspace') WHERE name = 'scenarios_json'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '25' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v25: {error}")));
    }
    conn.execute_batch(POLICY_SCENARIOS_DDL)
        .map_err(|error| db_error(format!("migrate v24 -> v25 policy scenarios: {error}")))
}
