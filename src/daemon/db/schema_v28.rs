use rusqlite::Connection;

use super::{CliError, db_error};

const REMOTE_ACME_CONFIG_DDL: &str =
    include_str!("migrations/0022_daemon_v28_remote_acme_config.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('remote_acme_state') WHERE name = 'domain'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '28' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v28: {error}")));
    }
    conn.execute_batch(REMOTE_ACME_CONFIG_DDL)
        .map_err(|error| db_error(format!("migrate v27 -> v28 remote acme config: {error}")))
}
