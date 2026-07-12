use rusqlite::Connection;

use super::{CliError, db_error};

const TASK_BOARD_DDL: &str = include_str!("migrations/0024_daemon_v30_task_board.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(TASK_BOARD_DDL)
        .map_err(|error| db_error(format!("apply task board schema v30: {error}")))
}
