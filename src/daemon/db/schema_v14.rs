use rusqlite::Connection;

use super::{CliError, db_error};

/// Policy-graph storage tables (schema v14). The same DDL feeds the async sqlx
/// migrator via `migrations/0008_daemon_v14_policy_graph.sql`; this sync path
/// applies it (including the `schema_meta` version bump) for databases opened
/// through [`super::DaemonDb`]. The statements are `IF NOT EXISTS` so a database
/// already advanced by the async migrator stays untouched.
const POLICY_GRAPH_DDL: &str = include_str!("migrations/0008_daemon_v14_policy_graph.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(POLICY_GRAPH_DDL)
        .map_err(|error| db_error(format!("migrate v13 -> v14 policy graph: {error}")))
}
