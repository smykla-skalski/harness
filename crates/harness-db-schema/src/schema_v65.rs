use rusqlite::Connection;

use super::CliError;
use super::schema_repairs_shape_probes::{column_exists, table_exists};

const WORKING_COPIES_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0066_daemon_v65_agent_working_copies.sql"
);
const AGENT_TUI_WORKSPACE_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0067_daemon_v65_agent_tui_workspace.sql"
);
const CODEX_RUN_WORKSPACE_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0068_daemon_v65_codex_run_workspace.sql"
);
const TASK_BOARD_LINKS_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0069_daemon_v65_task_board_workspace_links.sql"
);
const DISPATCH_INTENT_WORKSPACE_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0070_daemon_v65_dispatch_intent_workspace.sql"
);

/// Give durable workspaces their own checkouts, and let managed agents, board
/// items, and dispatch intents name a workspace instead of a Session.
///
/// The repair chain replays every version step against databases that may
/// already be at this shape, so each part is skipped once its own effect is
/// visible. The table rebuilds in particular are not self-idempotent: replaying
/// one would copy its rows back with a NULL `workspace_id` and drop the
/// ownership this migration exists to record.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    apply(conn, "agent working copies", WORKING_COPIES_SQL)?;
    if table_exists(conn, "agent_tuis")? && !column_exists(conn, "agent_tuis", "workspace_id")? {
        apply(
            conn,
            "terminal workspace ownership",
            AGENT_TUI_WORKSPACE_SQL,
        )?;
    }
    if table_exists(conn, "codex_runs")? && !column_exists(conn, "codex_runs", "workspace_id")? {
        apply(
            conn,
            "codex run workspace ownership",
            CODEX_RUN_WORKSPACE_SQL,
        )?;
    }
    if table_exists(conn, "task_board_items")?
        && !column_exists(conn, "task_board_items", "workspace_id")?
    {
        apply(conn, "task board workspace links", TASK_BOARD_LINKS_SQL)?;
    }
    if table_exists(conn, "task_board_dispatch_intents")?
        && !column_exists(conn, "task_board_dispatch_intents", "workspace_id")?
    {
        apply(
            conn,
            "dispatch intent workspace ownership",
            DISPATCH_INTENT_WORKSPACE_SQL,
        )?;
    }
    stamp_schema_version(conn)
}

/// The dispatch-intent file carries its own `BEGIN`/`COMMIT` and suspends
/// foreign keys around the swap, so it must not be wrapped in a transaction
/// here - the pragma would be a no-op and the swap would rewrite the admission
/// children's foreign keys. `execute_batch` runs it exactly as written.
fn apply(conn: &Connection, label: &str, sql: &str) -> Result<(), CliError> {
    conn.execute_batch(sql)
        .map_err(|error| super::db_error(format!("apply schema v65 {label}: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '65' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| super::db_error(format!("stamp schema v65: {error}")))
}

#[cfg(test)]
#[path = "schema_v65_tests.rs"]
mod tests;
