use rusqlite::Connection;

use super::{CliError, db_error};

const POLICY_LIVE_CANVAS_DDL: &str =
    include_str!("migrations/0020_daemon_v26_policy_live_canvas.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('policy_canvases') WHERE name = 'live_document_json'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '26' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v26: {error}")));
    }
    conn.execute_batch(POLICY_LIVE_CANVAS_DDL)
        .map_err(|error| db_error(format!("migrate v25 -> v26 policy live canvas: {error}")))
}
