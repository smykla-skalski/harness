use rusqlite::Connection;

use super::{CliError, db_error};

/// Policy-canvas identity persistence (schema v15). Adds a durable marker for
/// the review-text-paste dry-run canvas plus a workspace tombstone so delete
/// survives restart.
const POLICY_CANVAS_IDENTITY_DDL: &str =
    include_str!("migrations/0009_daemon_v15_policy_canvas_identity.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    // SQLite has no ALTER TABLE ... ADD COLUMN IF NOT EXISTS. The columns can
    // already exist when a test manually downgrades schema_meta.version while
    // leaving the policy tables intact, or when the async sqlx migrator ran
    // migration 9 before the sync path. In both cases we must still stamp the
    // schema version to 15 so subsequent opens do not try to re-run.
    let already_applied: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('policy_workspace') \
             WHERE name = 'review_text_paste_dry_run_canvas_deleted'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .is_ok_and(|count| count > 0);
    if already_applied {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '15' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| db_error(format!("stamp schema v15: {error}")));
    }
    conn.execute_batch(POLICY_CANVAS_IDENTITY_DDL)
        .map_err(|error| db_error(format!("migrate v14 -> v15 policy canvas identity: {error}")))
}
