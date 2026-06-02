use rusqlite::Connection;

use super::{CliError, db_error};

/// Review screenshot extraction canvas identity persistence (schema v18).
const REVIEW_SCREENSHOT_CANVAS_DDL: &str =
    include_str!("migrations/0012_daemon_v18_review_screenshot_canvas.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('policy_workspace') \
             WHERE name = 'review_screenshot_extraction_canvas_deleted'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '18' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v18: {error}")));
    }
    conn.execute_batch(REVIEW_SCREENSHOT_CANVAS_DDL)
        .map_err(|error| {
            db_error(format!(
                "migrate v17 -> v18 review screenshot canvas: {error}"
            ))
        })
}
