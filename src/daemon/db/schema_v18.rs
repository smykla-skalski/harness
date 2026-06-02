use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if column_exists(
        conn,
        "policy_workspace",
        "review_screenshot_extraction_canvas_deleted",
    )? && column_exists(
        conn,
        "policy_canvases",
        "is_review_screenshot_extraction_canvas",
    )? {
        stamp_schema_version(conn)?;
        return Ok(());
    }
    if !column_exists(
        conn,
        "policy_workspace",
        "review_screenshot_extraction_canvas_deleted",
    )? {
        add_column_if_missing(
            conn,
            "policy_workspace",
            "review_screenshot_extraction_canvas_deleted",
            "ALTER TABLE policy_workspace
             ADD COLUMN review_screenshot_extraction_canvas_deleted INTEGER NOT NULL DEFAULT 0",
            "add v18 review screenshot workspace tombstone",
        )?;
    }
    if !column_exists(
        conn,
        "policy_canvases",
        "is_review_screenshot_extraction_canvas",
    )? {
        add_column_if_missing(
            conn,
            "policy_canvases",
            "is_review_screenshot_extraction_canvas",
            "ALTER TABLE policy_canvases
             ADD COLUMN is_review_screenshot_extraction_canvas INTEGER NOT NULL DEFAULT 0",
            "add v18 review screenshot canvas identity",
        )?;
    }
    conn.execute(
        "UPDATE policy_canvases
         SET is_review_screenshot_extraction_canvas = 1
         WHERE canvas_id IN (
             SELECT canvas_id
             FROM policy_canvases
             WHERE EXISTS (
                 SELECT 1
                 FROM json_each(policy_trace_ids_json)
                 WHERE value = 'review-screenshot-extraction-canvas-v1'
             )
             ORDER BY created_at, canvas_id
             LIMIT 1
         )",
        [],
    )
    .map_err(|error| db_error(format!("backfill v18 review screenshot canvas: {error}")))?;
    stamp_schema_version(conn)
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

fn add_column_if_missing(
    conn: &Connection,
    table_name: &str,
    column_name: &str,
    sql: &str,
    context: &str,
) -> Result<(), CliError> {
    match conn.execute(sql, []) {
        Ok(_) => Ok(()),
        Err(_) if column_exists(conn, table_name, column_name)? => Ok(()),
        Err(error) => Err(db_error(format!("{context}: {error}"))),
    }
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '18' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v18: {error}")))
}
