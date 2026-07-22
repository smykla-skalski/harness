use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "task_board_items",
        "kind",
        "kind TEXT NOT NULL DEFAULT 'task'",
    )?;
    conn.execute(
        "UPDATE schema_meta SET value = '42' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v42: {error}")))
}

fn add_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), CliError> {
    if column_exists(conn, table, column)? {
        return Ok(());
    }
    conn.execute(&format!("ALTER TABLE {table} ADD COLUMN {definition}"), [])
        .map(|_| ())
        .map_err(|error| db_error(format!("add {table}.{column}: {error}")))
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table, column],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table}.{column}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::run;
    use crate::daemon::db::DaemonDb;

    #[test]
    fn current_schema_has_the_kind_column_defaulted_to_task() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");

        assert_eq!(db.schema_version().expect("schema version"), "43");
        let exists: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_xinfo('task_board_items')
                 WHERE name = 'kind'",
                [],
                |row| row.get(0),
            )
            .expect("read task-board item column");
        assert_eq!(exists, 1, "missing task-board item column kind");
    }

    #[test]
    fn migration_is_restart_safe_and_backfills_existing_rows_to_the_default_kind() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        db.connection()
            .execute_batch(
                "INSERT INTO task_board_items (
                     item_id, schema_version, title, body, status, priority, tags_json,
                     project_id, target_project_types_json, agent_mode, imported_from_provider,
                     planning_json, workflow_json, session_id, work_item_id, usage_json,
                     parent_item_id, child_order, created_at, updated_at, deleted_at,
                     revision, workflow_kind, execution_repository
                 ) VALUES (
                     'existing-item', 1, 'Existing', '', 'todo', 'medium', '[]', NULL, '[]',
                     'headless', NULL, '{}', '{}', NULL, NULL, '{}', NULL, 0,
                     '2026-07-21T10:00:00Z', '2026-07-21T10:00:00Z', NULL, 1,
                     'default_task', NULL
                 );
                 ALTER TABLE task_board_items DROP COLUMN kind;
                 UPDATE schema_meta SET value = '41' WHERE key = 'version';",
            )
            .expect("restore a partially migrated v41 shape");

        run(db.connection()).expect("repair v42 migration");
        run(db.connection()).expect("repeat v42 migration");

        assert_eq!(db.schema_version().expect("schema version"), "42");
        let kind: String = db
            .connection()
            .query_row(
                "SELECT kind FROM task_board_items WHERE item_id = 'existing-item'",
                [],
                |row| row.get(0),
            )
            .expect("read backfilled kind");
        assert_eq!(
            kind, "task",
            "existing rows keep working under the default kind"
        );
    }
}
