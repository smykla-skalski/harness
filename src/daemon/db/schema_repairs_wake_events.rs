use super::{CliError, Connection, db_error};

const TABLE_NAME: &str = "task_board_orchestrator_wake_events";
const INDEX_NAME: &str = "task_board_orchestrator_wake_events_pending";
const EXPECTED_TABLE_SQL: &str = "
CREATE TABLE task_board_orchestrator_wake_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    cause TEXT NOT NULL,
    entity_id TEXT,
    entity_revision INTEGER,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    processed_at TEXT
)";
const EXPECTED_INDEX_SQL: &str = "
CREATE INDEX task_board_orchestrator_wake_events_pending
    ON task_board_orchestrator_wake_events(processed_at, sequence)";

pub(super) fn require_table_shape(conn: &Connection) -> Result<(), CliError> {
    require_object_shape(conn, "table", TABLE_NAME, EXPECTED_TABLE_SQL).map_err(|_| {
        db_error(
            "incompatible task_board_orchestrator_wake_events schema; refusing destructive repair",
        )
    })
}

pub(super) fn indexes_need_repair(conn: &Connection) -> Result<bool, CliError> {
    if !object_exists(conn, "index", INDEX_NAME)? {
        return Ok(true);
    }
    require_object_shape(conn, "index", INDEX_NAME, EXPECTED_INDEX_SQL).map_err(|_| {
        db_error(
            "incompatible task_board_orchestrator_wake_events_pending index; refusing destructive repair",
        )
    })?;
    Ok(false)
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    require_table_shape(conn)?;
    if indexes_need_repair(conn)? {
        return Err(db_error(
            "task-board wake-event repair left required indexes missing",
        ));
    }
    Ok(())
}

fn require_object_shape(
    conn: &Connection,
    object_type: &str,
    name: &str,
    expected_sql: &str,
) -> Result<(), CliError> {
    let stored_sql = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
            [object_type, name],
            |row| row.get::<_, String>(0),
        )
        .map_err(|error| db_error(format!("read {name} definition: {error}")))?;
    if normalize_sql(&stored_sql) == normalize_sql(expected_sql) {
        return Ok(());
    }
    Err(db_error(format!("unexpected {name} definition")))
}

fn object_exists(conn: &Connection, object_type: &str, name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = ?1 AND name = ?2",
        [object_type, name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {name} existence: {error}")))
}

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
