use super::{CliError, DaemonDb, db_error, session_status_db_label};
use crate::session::service::canonicalize_active_session_without_leader;
use crate::session::types::SessionState;
use crate::workspace::utc_now;
use serde_json::Value;

const CURRENT_SCHEMA_POLICY_COLUMNS: &[(&str, &str)] = &[
    ("policy_workspace", "manual_ocr_paste_canvas_deleted"),
    (
        "policy_workspace",
        "review_text_paste_dry_run_canvas_deleted",
    ),
    (
        "policy_workspace",
        "review_screenshot_extraction_canvas_deleted",
    ),
    ("policy_workspace", "global_policy_enforcement_enabled"),
    ("policy_workspace", "scenarios_json"),
    ("policy_workspace", "scenarios_seeded"),
    ("policy_canvases", "is_manual_ocr_paste_canvas"),
    ("policy_canvases", "is_review_text_paste_dry_run_canvas"),
    ("policy_canvases", "is_review_screenshot_extraction_canvas"),
    ("policy_canvases", "layout_zoom"),
    ("policy_canvases", "layout_offset_x"),
    ("policy_canvases", "layout_offset_y"),
    ("policy_canvases", "live_document_json"),
    ("policy_canvases", "live_updated_at"),
    ("policy_nodes", "layout_source"),
];

const DEPRECATED_SCHEMA_POLICY_COLUMNS: &[(&str, &str)] =
    &[("policy_workspace", "enforcement_snapshot_json")];

pub(super) fn current_schema_shape_needs_repair(
    conn: &super::Connection,
) -> Result<bool, CliError> {
    for table in [
        "policy_workspace",
        "policy_canvases",
        "policy_nodes",
        "policy_edges",
        "policy_groups",
        "policy_group_nodes",
        "audit_events",
        "policy_decisions",
    ] {
        if !table_exists(conn, table)? {
            return Ok(true);
        }
    }
    for (table, column) in CURRENT_SCHEMA_POLICY_COLUMNS {
        if !column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    for (table, column) in DEPRECATED_SCHEMA_POLICY_COLUMNS {
        if column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn repair_current_schema_shape(db: &DaemonDb) -> Result<(), CliError> {
    if !current_schema_shape_needs_repair(&db.conn)? {
        return Ok(());
    }

    super::schema_v14::run(&db.conn)?;
    super::schema_v15::run(&db.conn)?;
    super::schema_v16::run(&db.conn)?;
    super::schema_v17::run(&db.conn)?;
    super::schema_v18::run(&db.conn)?;
    super::schema_v19::run(&db.conn)?;
    super::schema_v20::run(&db.conn)?;
    super::schema_v21::run(&db.conn)?;
    super::schema_v22::run(&db.conn)?;
    super::schema_v23::run(&db.conn)?;
    super::schema_v24::run(&db.conn)?;
    super::schema_v25::run(&db.conn)?;
    super::schema_v26::run(&db.conn)?;
    db.conn
        .execute(
            "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
            [super::SCHEMA_VERSION],
        )
        .map(|_| ())
        .map_err(|error| db_error(format!("stamp repaired schema version: {error}")))
}

pub(super) fn repair_noncanonical_session_state_wire(db: &DaemonDb) -> Result<(), CliError> {
    let mut statement = db
        .conn
        .prepare("SELECT session_id, project_id, state_json FROM sessions")
        .map_err(|error| db_error(format!("prepare session wire repair scan: {error}")))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|error| db_error(format!("query session wire repair scan: {error}")))?;
    let all_rows = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read session wire repair row: {error}")))?;

    for (session_id, project_id, state_json) in all_rows {
        let mut value: Value = serde_json::from_str(&state_json)
            .map_err(|error| db_error(format!("parse session wire repair row: {error}")))?;
        if repair_session_state_wire_value(&mut value) {
            let state: SessionState = serde_json::from_value(value).map_err(|error| {
                db_error(format!("parse repaired session {session_id}: {error}"))
            })?;
            db.sync_session(&project_id, &state)?;
        }
    }

    Ok(())
}

fn repair_session_state_wire_value(value: &mut Value) -> bool {
    let Some(agents) = value
        .as_object_mut()
        .and_then(|object| object.get_mut("agents"))
        .and_then(Value::as_object_mut)
    else {
        return false;
    };

    let mut changed = false;
    for agent in agents.values_mut() {
        if let Some(agent) = agent.as_object_mut() {
            if !agent.contains_key("session_agent_id")
                && let Some(agent_id) = agent.get("agent_id").cloned()
            {
                agent.insert("session_agent_id".to_string(), agent_id);
                changed = true;
            }
            if !agent.contains_key("runtime_session_id")
                && let Some(runtime_session_id) = agent.get("agent_session_id").cloned()
            {
                agent.insert("runtime_session_id".to_string(), runtime_session_id);
                changed = true;
            }
        }
    }

    changed
}

pub(super) fn repair_stale_active_sessions_without_leader(db: &DaemonDb) -> Result<(), CliError> {
    let mut statement = db
        .conn
        .prepare(
            "SELECT project_id, status, leader_id, is_active, state_json
             FROM sessions
             WHERE status = 'active' AND leader_id IS NULL",
        )
        .map_err(|error| db_error(format!("prepare v9 session repair scan: {error}")))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .map_err(|error| db_error(format!("query v9 session repair scan: {error}")))?;
    let all_rows = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read v9 session repair row: {error}")))?;

    for (project_id, stored_status, stored_leader_id, stored_is_active, state_json) in all_rows {
        let mut state: SessionState = serde_json::from_str(&state_json)
            .map_err(|error| db_error(format!("parse v9 session state: {error}")))?;
        let repaired = canonicalize_active_session_without_leader(&mut state, &utc_now());
        if repaired
            || session_row_needs_resync(
                &state,
                &stored_status,
                stored_leader_id.as_deref(),
                stored_is_active,
            )?
        {
            db.sync_session(&project_id, &state)?;
        }
    }
    Ok(())
}

fn session_row_needs_resync(
    state: &SessionState,
    stored_status: &str,
    stored_leader_id: Option<&str>,
    stored_is_active: i64,
) -> Result<bool, CliError> {
    let canonical_status = session_status_db_label(state.status)?;
    let canonical_is_active = i64::from(state.status.is_default_visible());
    Ok(stored_status != canonical_status
        || stored_leader_id != state.leader_id.as_deref()
        || stored_is_active != canonical_is_active)
}

fn table_exists(conn: &super::Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name} table existence: {error}")))
}

fn column_exists(
    conn: &super::Connection,
    table_name: &str,
    column_name: &str,
) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table_name, column_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name}.{column_name}: {error}")))
}
