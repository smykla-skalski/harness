use rusqlite::Connection;

use super::CliError;

const AI_REVIEW_REPORTS_SQL: &str =
    include_str!("../../harness-daemon/src/daemon/db/migrations/0057_daemon_v58_ai_review_reports.sql");

/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(AI_REVIEW_REPORTS_SQL).map_err(|error| {
        super::db_error(format!(
            "apply schema v58 AI review reports migration: {error}"
        ))
    })
}
