use rusqlite::Connection;

use super::{CliError, db_error};

const HELD_DISPATCH_DDL: &str = include_str!("migrations/0027_daemon_v33_held_dispatch.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(HELD_DISPATCH_DDL)
        .map_err(|error| db_error(format!("apply held dispatch schema v33: {error}")))
}
