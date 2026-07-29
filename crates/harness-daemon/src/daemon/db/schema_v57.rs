use rusqlite::Connection;

use super::CliError;

const PULL_REQUEST_ACTIONS_SQL: &str =
    include_str!("migrations/0056_daemon_v57_pull_request_actions.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    // Safe to repeat: the table create guards with IF NOT EXISTS and the stamp
    // is idempotent, so the repair replay can re-run this step. The file carries
    // the version stamp in the same batch, as the migrations before it do.
    conn.execute_batch(PULL_REQUEST_ACTIONS_SQL).map_err(|error| {
        super::db_error(format!(
            "apply schema v57 pull request actions migration: {error}"
        ))
    })
}
