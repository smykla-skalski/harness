use super::{CliError, DaemonDb, db_error, session_status_db_label};
use crate::session::service::canonicalize_active_session_without_leader;
use crate::session::types::SessionState;
use crate::workspace::utc_now;
use serde_json::Value;

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
