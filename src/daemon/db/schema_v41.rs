use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "task_board_items",
        "parent_item_id",
        "parent_item_id TEXT",
    )?;
    add_column_if_missing(
        conn,
        "task_board_items",
        "child_order",
        "child_order INTEGER NOT NULL DEFAULT 0",
    )?;
    conn.execute(
        "CREATE INDEX IF NOT EXISTS task_board_items_parent
             ON task_board_items(parent_item_id, child_order)",
        [],
    )
    .map_err(|error| db_error(format!("create v41 parent index: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = '41' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v41: {error}")))
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
    fn current_schema_has_parent_link_columns_and_index() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");

        assert_eq!(db.schema_version().expect("schema version"), "42");
        for column in ["parent_item_id", "child_order"] {
            let exists: i64 = db
                .connection()
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_xinfo('task_board_items')
                     WHERE name = ?1",
                    [column],
                    |row| row.get(0),
                )
                .expect("read task-board item column");
            assert_eq!(exists, 1, "missing task-board item column {column}");
        }
        let index_exists: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                 WHERE type = 'index' AND name = 'task_board_items_parent'",
                [],
                |row| row.get(0),
            )
            .expect("read parent index");
        assert_eq!(index_exists, 1, "missing task_board_items_parent index");
    }

    #[test]
    fn migration_is_restart_safe_and_preserves_the_parent_link() {
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
                     'parent-item', 1, 'Parent', '', 'todo', 'medium', '[]', NULL, '[]',
                     'headless', NULL, '{}', '{}', NULL, NULL, '{}', NULL, 0,
                     '2026-07-21T10:00:00Z', '2026-07-21T10:00:00Z', NULL, 1,
                     'default_task', NULL
                 ),
                 (
                     'child-item', 1, 'Child', '', 'todo', 'medium', '[]', NULL, '[]',
                     'headless', NULL, '{}', '{}', NULL, NULL, '{}', 'parent-item', 3,
                     '2026-07-21T10:00:00Z', '2026-07-21T10:00:00Z', NULL, 1,
                     'default_task', NULL
                 );
                 DROP INDEX task_board_items_parent;
                 ALTER TABLE task_board_items DROP COLUMN child_order;
                 UPDATE schema_meta SET value = '40' WHERE key = 'version';",
            )
            .expect("restore a partially migrated v40 shape");

        run(db.connection()).expect("repair v41 migration");
        run(db.connection()).expect("repeat v41 migration");

        assert_eq!(db.schema_version().expect("schema version"), "41");
        let (parent_item_id, child_order): (Option<String>, i64) = db
            .connection()
            .query_row(
                "SELECT parent_item_id, child_order FROM task_board_items
                 WHERE item_id = 'child-item'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read preserved parent link");
        assert_eq!(parent_item_id.as_deref(), Some("parent-item"));
        assert_eq!(
            child_order, 0,
            "dropped column repair backfills the default"
        );
    }
}
