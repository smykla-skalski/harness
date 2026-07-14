use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let needs_grant_tracking = table_exists(conn, "task_board_dispatch_intents")?
        && !column_exists(
            conn,
            "task_board_dispatch_intents",
            "consumed_approval_grant_id",
        )?;
    if needs_grant_tracking {
        conn.execute(
            "ALTER TABLE task_board_dispatch_intents
             ADD COLUMN consumed_approval_grant_id TEXT",
            [],
        )
        .map_err(|error| db_error(format!("add v35 dispatch grant tracking: {error}")))?;
        conn.execute(
            "UPDATE policy_workspace SET spawn_requires_live_policy = 1",
            [],
        )
        .map_err(|error| db_error(format!("close v35 spawn policy: {error}")))?;
    }
    conn.execute(
        "UPDATE schema_meta SET value = '35' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v35: {error}")))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_closes_spawn_policy_and_adds_grant_tracking() {
        let conn = Connection::open_in_memory().expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta (key, value) VALUES ('version', '34');
             CREATE TABLE policy_workspace (
                 singleton INTEGER PRIMARY KEY,
                 spawn_requires_live_policy INTEGER NOT NULL DEFAULT 0
             );
             INSERT INTO policy_workspace VALUES (1, 0);
             CREATE TABLE task_board_dispatch_intents (intent_id TEXT PRIMARY KEY);",
        )
        .expect("seed v34 schema");

        run(&conn).expect("run v35 migration");

        let requires_live: bool = conn
            .query_row(
                "SELECT spawn_requires_live_policy FROM policy_workspace WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .expect("read migrated switch");
        assert!(requires_live, "v35 migration must fail closed");
        assert!(
            column_exists(
                &conn,
                "task_board_dispatch_intents",
                "consumed_approval_grant_id"
            )
            .expect("inspect dispatch schema")
        );
    }
}
