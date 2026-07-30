use rusqlite::Connection;

use super::CliError;

const AGENT_TURN_RUNS_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0058_daemon_v59_agent_turn_runs.sql"
);

/// Safe to repeat: the table and indexes guard with IF NOT EXISTS and the stamp
/// is idempotent, so the repair replay can re-run this step.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(AGENT_TURN_RUNS_SQL).map_err(|error| {
        super::db_error(format!(
            "apply schema v59 agent turn runs migration: {error}"
        ))
    })
}
