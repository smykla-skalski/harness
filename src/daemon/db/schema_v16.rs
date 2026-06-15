use rusqlite::Connection;

use super::{CliError, db_error};

const POLICY_WORKSPACE_FLAGS_DDL: &str =
    include_str!("migrations/0010_daemon_v16_policy_workspace_flags.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(POLICY_WORKSPACE_FLAGS_DDL)
        .map_err(|error| db_error(format!("migrate v15 -> v16 policy workspace flags: {error}")))
}
