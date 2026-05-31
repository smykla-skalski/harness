use rusqlite::Connection;

use super::{CliError, db_error};

/// Policy-canvas identity persistence (schema v15). Adds a durable marker for
/// the review-text-paste dry-run canvas plus a workspace tombstone so delete
/// survives restart.
const POLICY_CANVAS_IDENTITY_DDL: &str =
    include_str!("migrations/0009_daemon_v15_policy_canvas_identity.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(POLICY_CANVAS_IDENTITY_DDL)
        .map_err(|error| db_error(format!("migrate v14 -> v15 policy canvas identity: {error}")))
}
