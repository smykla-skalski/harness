use rusqlite::Connection;

use super::{CliError, db_error};

const AUDIT_EVENTS_DDL: &str = include_str!("migrations/0011_daemon_v17_audit_events.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='audit_events'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '17' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v17: {error}")));
    }
    conn.execute_batch(AUDIT_EVENTS_DDL)
        .map_err(|error| db_error(format!("migrate v16 -> v17 audit events: {error}")))
}
