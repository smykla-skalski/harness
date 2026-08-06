use std::collections::BTreeMap;
use std::iter::repeat_n;

use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::session::{AgentRegistration, ManagedAgentKind};
use harness_session::service::agent_status_db_label;
use rusqlite::Connection;

pub(super) fn replace_agents(
    transaction: &Connection,
    session_id: &str,
    agents: &BTreeMap<String, AgentRegistration>,
) -> Result<(), CliError> {
    delete_stale_agents(transaction, session_id, agents)?;

    let mut statement = transaction
        .prepare(
            "INSERT INTO agents (
                agent_id, session_id, name, runtime, role, capabilities_json,
                status, agent_session_id, managed_agent_kind, managed_agent_id, joined_at, updated_at,
                last_activity_at, current_task_id, runtime_capabilities_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(session_id, agent_id) DO UPDATE SET
                name = excluded.name,
                runtime = excluded.runtime,
                role = excluded.role,
                capabilities_json = excluded.capabilities_json,
                status = excluded.status,
                agent_session_id = excluded.agent_session_id,
                managed_agent_kind = excluded.managed_agent_kind,
                managed_agent_id = excluded.managed_agent_id,
                joined_at = excluded.joined_at,
                updated_at = excluded.updated_at,
                last_activity_at = excluded.last_activity_at,
                current_task_id = excluded.current_task_id,
                runtime_capabilities_json = excluded.runtime_capabilities_json",
        )
        .map_err(|error| db_error(format!("prepare agent upsert: {error}")))?;

    for (agent_id, agent) in agents {
        let capabilities_json = serde_json::to_string(&agent.capabilities).unwrap_or_default();
        let runtime_capabilities_json =
            serde_json::to_string(&agent.runtime_capabilities).unwrap_or_default();
        let managed_agent_kind = agent
            .managed_agent
            .as_ref()
            .map(|managed| match managed.kind {
                ManagedAgentKind::Tui => "tui",
                ManagedAgentKind::Acp => "acp",
                ManagedAgentKind::Codex => "codex",
            });
        let managed_agent_id = agent
            .managed_agent
            .as_ref()
            .map(|managed| managed.id.as_str());

        statement
            .execute(rusqlite::params![
                agent_id,
                session_id,
                agent.name,
                agent.runtime.runtime_name(),
                format!("{:?}", agent.role).to_lowercase(),
                capabilities_json,
                agent_status_db_label(&agent.status),
                agent.agent_session_id,
                managed_agent_kind,
                managed_agent_id,
                agent.joined_at,
                agent.updated_at,
                agent.last_activity_at,
                agent.current_task_id,
                runtime_capabilities_json,
            ])
            .map_err(|error| db_error(format!("upsert agent {agent_id}: {error}")))?;
    }
    Ok(())
}

fn delete_stale_agents(
    transaction: &Connection,
    session_id: &str,
    agents: &BTreeMap<String, AgentRegistration>,
) -> Result<(), CliError> {
    if agents.is_empty() {
        transaction
            .execute("DELETE FROM agents WHERE session_id = ?1", [session_id])
            .map_err(|error| db_error(format!("delete agents: {error}")))?;
        return Ok(());
    }

    let placeholders = repeat_n("?", agents.len()).collect::<Vec<_>>().join(", ");
    let sql =
        format!("DELETE FROM agents WHERE session_id = ?1 AND agent_id NOT IN ({placeholders})");
    let agent_ids = agents.keys().map(String::as_str).collect::<Vec<_>>();
    let mut params = Vec::with_capacity(agent_ids.len() + 1);
    params.push(session_id);
    params.extend(agent_ids);
    transaction
        .execute(&sql, rusqlite::params_from_iter(params))
        .map_err(|error| db_error(format!("delete stale agents: {error}")))?;
    Ok(())
}
