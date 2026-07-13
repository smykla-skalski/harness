use rusqlite::Connection;

use super::{CliError, db_error};

const CODEX_TASK_BINDING_DDL: &str =
    include_str!("migrations/0026_daemon_v32_codex_task_binding.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(CODEX_TASK_BINDING_DDL)
        .map_err(|error| db_error(format!("apply codex task binding schema v32: {error}")))
}
