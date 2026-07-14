use rusqlite::Connection;

use super::{CliError, db_error};

const CREATE_APPROVAL_GRANTS_DDL: &str = "
CREATE TABLE IF NOT EXISTS policy_approval_grants (
    id             TEXT PRIMARY KEY,
    board_item_id  TEXT NOT NULL,
    action         TEXT NOT NULL,
    canvas_id      TEXT,
    canvas_revision INTEGER NOT NULL,
    node_id        TEXT NOT NULL,
    reason_code    TEXT NOT NULL,
    state          TEXT NOT NULL DEFAULT 'pending',
    resolved_by    TEXT,
    resolved_at    TEXT,
    consumed_at    TEXT,
    expiry_seconds INTEGER,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS idx_policy_approval_grants_live_key
    ON policy_approval_grants(board_item_id, action, canvas_revision)
    WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_policy_approval_grants_state
    ON policy_approval_grants(state, created_at DESC);";

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(CREATE_APPROVAL_GRANTS_DDL)
        .map_err(|error| db_error(format!("create policy approval grants v34: {error}")))?;
    add_column_if_missing(
        conn,
        "policy_decisions",
        "evaluated_at",
        "ALTER TABLE policy_decisions ADD COLUMN evaluated_at TEXT",
    )?;
    add_column_if_missing(
        conn,
        "policy_workspace",
        "spawn_requires_live_policy",
        "ALTER TABLE policy_workspace
         ADD COLUMN spawn_requires_live_policy INTEGER NOT NULL DEFAULT 1",
    )?;
    add_column_if_missing(
        conn,
        "policy_workspace",
        "spawn_kill_switch",
        "ALTER TABLE policy_workspace ADD COLUMN spawn_kill_switch INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_missing(
        conn,
        "task_board_dispatch_intents",
        "consumed_approval_grant_id",
        "ALTER TABLE task_board_dispatch_intents
         ADD COLUMN consumed_approval_grant_id TEXT",
    )?;
    stamp_schema_version(conn)
}

/// Add a column, tolerating both a synthetic legacy fixture that never created
/// the target table (skip) and a database where the column already exists (the
/// forward sqlx migrator applied it). Only a genuine failure against an existing
/// table propagates.
fn add_column_if_missing(
    conn: &Connection,
    table_name: &str,
    column_name: &str,
    sql: &str,
) -> Result<(), CliError> {
    if !table_exists(conn, table_name)? {
        return Ok(());
    }
    match conn.execute(sql, []) {
        Ok(_) => Ok(()),
        Err(_) if column_exists(conn, table_name, column_name)? => Ok(()),
        Err(error) => Err(db_error(format!(
            "add v34 column {table_name}.{column_name}: {error}"
        ))),
    }
}

fn table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check table {table_name}: {error}")))
}

fn column_exists(conn: &Connection, table_name: &str, column_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table_name, column_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name}.{column_name}: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '34' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v34: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_defaults_existing_workspace_to_fail_closed_spawn() {
        let conn = Connection::open_in_memory().expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta (key, value) VALUES ('version', '33');
             CREATE TABLE policy_workspace (
                 singleton INTEGER PRIMARY KEY,
                 active_canvas_id TEXT NOT NULL,
                 workspace_schema_version INTEGER NOT NULL,
                 updated_at TEXT NOT NULL
             );
             INSERT INTO policy_workspace VALUES (1, 'canvas-1', 1, '2026-07-14T10:00:00Z');",
        )
        .expect("seed v33 workspace");

        run(&conn).expect("run v34 migration");

        let requires_live: bool = conn
            .query_row(
                "SELECT spawn_requires_live_policy FROM policy_workspace WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .expect("read migrated switch");
        assert!(requires_live, "migration must default existing rows closed");
    }
}
