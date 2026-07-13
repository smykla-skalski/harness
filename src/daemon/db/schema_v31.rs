use rusqlite::Connection;

use super::{CliError, db_error};

const REMOTE_CLIENT_ACTIVITY_DDL: &str =
    include_str!("migrations/0025_daemon_v31_remote_client_activity.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(REMOTE_CLIENT_ACTIVITY_DDL)
        .map_err(|error| db_error(format!("apply remote client activity schema v31: {error}")))
}
