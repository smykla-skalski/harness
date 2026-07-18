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
    ("policy_workspace", "spawn_requires_live_policy"),
    ("policy_workspace", "spawn_kill_switch"),
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
    ("policy_decisions", "evaluated_at"),
    ("task_board_dispatch_intents", "consumed_approval_grant_id"),
    ("task_board_dispatch_intents", "compensation_pending"),
    ("task_board_items", "workflow_kind"),
    ("task_board_items", "execution_repository"),
    ("task_board_items", "estimated_tokens"),
    ("task_board_items", "estimated_cost_microusd"),
];

const CURRENT_SCHEMA_CODEX_RUN_COLUMNS: &[(&str, &str)] = &[
    ("codex_runs", "task_id"),
    ("codex_runs", "board_item_id"),
    ("codex_runs", "workflow_execution_id"),
];

const DEPRECATED_SCHEMA_POLICY_COLUMNS: &[(&str, &str)] =
    &[("policy_workspace", "enforcement_snapshot_json")];
const CURRENT_SCHEMA_TRIGGERS: &[&str] = &["remote_audit_events_touch_client_activity"];

const CURRENT_SCHEMA_REMOTE_ACME_COLUMNS: &[(&str, &str)] = &[
    ("remote_acme_state", "domain"),
    ("remote_acme_state", "host"),
    ("remote_acme_state", "https_port"),
    ("remote_acme_state", "http_port"),
    ("remote_acme_state", "acme_email"),
    ("remote_acme_state", "acme_challenge"),
    ("remote_acme_state", "acme_dns_provider"),
    ("remote_acme_state", "account_credentials_json"),
];

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
        "remote_acme_state",
        "remote_audit_events",
        "remote_clients",
        "remote_pairing_codes",
        "policy_decisions",
        "task_board_items",
        "task_board_identity",
        "task_board_external_refs",
        "task_board_machines",
        "task_board_local_machine",
        "task_board_orchestrator_settings",
        "task_board_orchestrator_state",
        "task_board_runtime_config",
        "policy_workflow_runs",
        "policy_event_inbox",
        "policy_handoff_outbox",
        "policy_notification_outbox",
        "policy_task_creation_outbox",
        "policy_approval_grants",
        "task_board_dispatch_intents",
        "task_board_imports",
        "task_board_orchestrator_control",
        "task_board_orchestrator_runs",
        "task_board_workflow_executions",
        "task_board_execution_attempts",
        "task_board_admission_leases",
        "task_board_provider_scope_state",
        "task_board_external_create_intents",
        "task_board_dispatch_admission_decisions",
        "task_board_dispatch_admission_ledger",
        "task_board_sync_conflicts",
        "task_board_execution_hosts",
        "task_board_remote_assignments",
        "task_board_orchestrator_wake_events",
        "task_board_reconciliation_cursors",
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
    for (table, column) in CURRENT_SCHEMA_CODEX_RUN_COLUMNS {
        if !column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    super::schema_repairs_external_creates::require_table_shape(conn)?;
    super::schema_repairs_wake_events::require_table_shape(conn)?;
    if !table_sql_contains(conn, "task_board_dispatch_intents", "'held'")? {
        return Ok(true);
    }
    for (table, column) in CURRENT_SCHEMA_REMOTE_ACME_COLUMNS {
        if !column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    for (table, column) in DEPRECATED_SCHEMA_POLICY_COLUMNS {
        if column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    for trigger in CURRENT_SCHEMA_TRIGGERS {
        if !trigger_exists(conn, trigger)? {
            return Ok(true);
        }
    }
    if super::schema_repairs_external_creates::indexes_need_repair(conn)? {
        return Ok(true);
    }
    if super::schema_repairs_wake_events::indexes_need_repair(conn)? {
        return Ok(true);
    }
    if super::schema_repairs_admission::shape_needs_repair(conn)? {
        return Ok(true);
    }
    if super::schema_repairs_reconciliation_cursors::shape_needs_repair(conn)? {
        return Ok(true);
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
    super::schema_v27::run(&db.conn)?;
    super::schema_v28::run(&db.conn)?;
    super::schema_v29::run(&db.conn)?;
    super::schema_v30::run(&db.conn)?;
    super::schema_v31::run(&db.conn)?;
    super::schema_v32::run(&db.conn)?;
    super::schema_v33::run(&db.conn)?;
    super::schema_v34::run(&db.conn)?;
    super::schema_v35::run(&db.conn)?;
    super::schema_v36::run(&db.conn)?;
    super::schema_v37::run(&db.conn)?;
    super::schema_v38::run(&db.conn)?;
    super::schema_v39::run(&db.conn)?;
    super::schema_v40::run(&db.conn)?;
    super::schema_repairs_external_creates::require_complete_shape(&db.conn)?;
    super::schema_repairs_wake_events::require_complete_shape(&db.conn)?;
    super::schema_repairs_admission::require_complete_shape(&db.conn)?;
    super::schema_repairs_reconciliation_cursors::require_complete_shape(&db.conn)?;
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

fn trigger_exists(conn: &super::Connection, trigger_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
        [trigger_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {trigger_name} trigger existence: {error}")))
}

fn table_sql_contains(
    conn: &super::Connection,
    table_name: &str,
    expected: &str,
) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, String>(0),
    )
    .map(|sql| sql.contains(expected))
    .map_err(|error| db_error(format!("read {table_name} table definition: {error}")))
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
