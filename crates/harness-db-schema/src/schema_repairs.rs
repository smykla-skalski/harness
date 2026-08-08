use harness_protocol::session::{SessionState, SessionStatus};
use harness_session::service::canonicalize_active_session_without_leader;
use harness_workspace::workspace::utc_now;
use serde_json::Value;

use super::{CliError, Connection, db_error};

mod current_objects;

/// Mirrors `harness-daemon`'s own `db::session_status_db_label`: the schema
/// history has no dependency back on `DaemonDb`, so this repair pass carries
/// its own copy of the one-line status-to-wire-label conversion rather than
/// reaching into the crate it was extracted from.
fn session_status_db_label(status: SessionStatus) -> Result<String, CliError> {
    let value = serde_json::to_value(status)
        .map_err(|error| db_error(format!("serialize session status: {error}")))?;
    value
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| db_error("serialize session status: expected string"))
}

pub(super) fn normalize_schema_sql(sql: &str) -> String {
    let mut normalized = String::with_capacity(sql.len());
    let mut in_literal = false;
    let mut pending_space = false;
    for character in sql.chars() {
        if character == '\'' {
            if pending_space && !normalized.is_empty() && !normalized.ends_with('(') {
                normalized.push(' ');
            }
            pending_space = false;
            normalized.push(character);
            in_literal = !in_literal;
        } else if !in_literal && character.is_whitespace() {
            pending_space = true;
        } else {
            if pending_space
                && !normalized.is_empty()
                && !normalized.ends_with('(')
                && character != ')'
            {
                normalized.push(' ');
            }
            pending_space = false;
            normalized.push(if in_literal {
                character
            } else {
                character.to_ascii_lowercase()
            });
        }
    }
    remove_outside_literal(&normalized, "if not exists ")
}

fn remove_outside_literal(sql: &str, pattern: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 0;
    let mut in_literal = false;
    while index < sql.len() {
        if !in_literal && sql[index..].starts_with(pattern) {
            index += pattern.len();
            continue;
        }
        let character = sql[index..]
            .chars()
            .next()
            .expect("index remains on a character boundary");
        if character == '\'' {
            in_literal = !in_literal;
        }
        result.push(character);
        index += character.len_utf8();
    }
    result
}

/// `pub`, not `pub(super)`: `harness-daemon`'s own async pool bootstrap calls
/// this directly to decide whether a reopened database needs the sync repair
/// pass.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn current_schema_shape_needs_repair(conn: &super::Connection) -> Result<bool, CliError> {
    if current_objects::shape_needs_repair(conn)? {
        return Ok(true);
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
    if super::schema_repairs_remote_execution::shape_needs_repair(conn)? {
        return Ok(true);
    }
    if super::schema_v44::shape_needs_repair(conn)? {
        return Ok(true);
    }
    if super::schema_repairs_remote_execution_v45::shape_needs_repair(conn)? {
        return Ok(true);
    }
    if super::schema_repairs_triage::shape_needs_repair(conn)? {
        return Ok(true);
    }
    if super::schema_repairs_triage_override::shape_needs_repair(conn)? {
        return Ok(true);
    }
    Ok(false)
}

/// `pub`, not `pub(super)`: `harness-daemon`'s own `ensure_schema` calls this
/// directly. `target_version` is the caller's compiled-in `SCHEMA_VERSION`,
/// passed in rather than duplicated here, since owning a second copy of that
/// constant would let the two drift.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn repair_current_schema_shape(
    conn: &Connection,
    target_version: &str,
) -> Result<(), CliError> {
    if !current_schema_shape_needs_repair(conn)? {
        return Ok(());
    }

    super::schema_v14::run(conn)?;
    super::schema_v15::run(conn)?;
    super::schema_v16::run(conn)?;
    super::schema_v17::run(conn)?;
    super::schema_v18::run(conn)?;
    super::schema_v19::run(conn)?;
    super::schema_v20::run(conn)?;
    super::schema_v21::run(conn)?;
    super::schema_v22::run(conn)?;
    super::schema_v23::run(conn)?;
    super::schema_v24::run(conn)?;
    super::schema_v25::run(conn)?;
    super::schema_v26::run(conn)?;
    super::schema_v27::run(conn)?;
    super::schema_v28::run(conn)?;
    super::schema_v29::run(conn)?;
    super::schema_v30::run(conn)?;
    super::schema_v31::run(conn)?;
    super::schema_v32::run(conn)?;
    super::schema_v33::run(conn)?;
    super::schema_v34::run(conn)?;
    super::schema_v35::run(conn)?;
    super::schema_v36::run(conn)?;
    super::schema_v37::run(conn)?;
    super::schema_v38::run(conn)?;
    super::schema_v39::run(conn)?;
    super::schema_v40::run(conn)?;
    super::schema_v41::run(conn)?;
    super::schema_v42::run(conn)?;
    super::schema_v43::run(conn)?;
    super::schema_v44::run(conn)?;
    super::schema_v45::run(conn)?;
    super::schema_v46::run(conn)?;
    super::schema_v47::run(conn)?;
    super::schema_v48::run(conn)?;
    super::schema_v49::run(conn)?;
    super::schema_v50::run(conn)?;
    super::schema_v51::run(conn)?;
    super::schema_v52::run(conn)?;
    super::schema_v53::run(conn)?;
    // v51 recreates task_board_projects from its original DDL, which still
    // names 'todoist' in the source check. Replaying v54 behind it is what
    // keeps a repaired database from being stamped current with the old shape.
    super::schema_v54::run(conn)?;
    super::schema_v55::run(conn)?;
    super::schema_v56::run(conn)?;
    super::schema_v57::run(conn)?;
    super::schema_v58::run(conn)?;
    super::schema_v59::run(conn)?;
    super::schema_v60::run(conn)?;
    super::schema_v61::run(conn)?;
    super::schema_v62::run(conn)?;
    super::schema_v63::run(conn)?;
    super::schema_v64::run(conn)?;
    super::schema_v65::run(conn)?;
    super::schema_v66::run(conn)?;
    super::schema_v67::run(conn)?;
    super::schema_v68::run(conn)?;
    super::schema_v69::run(conn)?;
    super::schema_repairs_external_creates::require_complete_shape(conn)?;
    super::schema_repairs_wake_events::require_complete_shape(conn)?;
    super::schema_repairs_admission::require_complete_shape(conn)?;
    super::schema_repairs_reconciliation_cursors::require_complete_shape(conn)?;
    super::schema_repairs_remote_execution::require_complete_shape(conn)?;
    super::schema_repairs_remote_execution_v45::require_complete_shape(conn)?;
    super::schema_repairs_triage::require_complete_shape(conn)?;
    super::schema_repairs_triage_override::require_complete_shape(conn)?;
    conn.execute(
        "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
        [target_version],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp repaired schema version: {error}")))
}

/// `pub`, not `pub(super)`: `harness-daemon`'s own `ensure_schema` calls this
/// directly. `sync_session` closes over the caller's `DaemonDb::sync_session`
/// so this repair pass stays free of a dependency back on that type: it only
/// ever touches `conn` directly and hands the caller each repaired session to
/// persist through its own normal write path.
///
/// # Errors
/// Returns [`CliError`] on SQL failures, or whatever `sync_session` returns.
pub fn repair_noncanonical_session_state_wire<F>(
    conn: &Connection,
    mut sync_session: F,
) -> Result<(), CliError>
where
    F: FnMut(&str, &SessionState) -> Result<(), CliError>,
{
    let mut statement = conn
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
            sync_session(&project_id, &state)?;
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

/// `pub`, not `pub(super)`: `harness-daemon`'s own `migrate_v8_to_v9` calls
/// this directly, for the same reason
/// [`repair_noncanonical_session_state_wire`] takes a `sync_session` closure
/// instead of a `DaemonDb`.
///
/// # Errors
/// Returns [`CliError`] on SQL failures, or whatever `sync_session` returns.
pub fn repair_stale_active_sessions_without_leader<F>(
    conn: &Connection,
    mut sync_session: F,
) -> Result<(), CliError>
where
    F: FnMut(&str, &SessionState) -> Result<(), CliError>,
{
    let mut statement = conn
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
            sync_session(&project_id, &state)?;
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

#[cfg(test)]
#[path = "schema_repairs_tests.rs"]
mod tests;
