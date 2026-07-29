use rusqlite::Connection;

use super::{CliError, db_error};

const REMOTE_IDENTITY_DDL: &str = include_str!("migrations/0021_daemon_v27_remote_identity.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(REMOTE_IDENTITY_DDL)
        .map_err(|error| db_error(format!("migrate v26 -> v27 remote identity: {error}")))
}
