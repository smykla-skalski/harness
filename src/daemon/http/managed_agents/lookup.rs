use crate::errors::{CliError, CliErrorKind};

use super::super::DaemonHttpState;
use super::run_terminal_agent_blocking;

pub(crate) async fn ensure_terminal_agent_async(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<(), CliError> {
    let agent_id_owned = agent_id.to_string();
    if run_terminal_agent_blocking(state, "lookup terminal agent", move |manager| {
        manager.get(&agent_id_owned)
    })
    .await
    .is_ok()
    {
        return Ok(());
    }
    if state.codex_controller.run(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a codex thread; expected a terminal managed_agent_id"
        ))
        .into());
    }
    if state.acp_agent_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is an ACP managed agent; expected a terminal managed_agent_id"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!(
        "managed agent '{agent_id}' not found; expected managed_agent_id"
    ))
    .into())
}

pub(crate) fn ensure_codex_agent(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    if state.codex_controller.run(agent_id).is_ok() {
        return Ok(());
    }
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a terminal managed agent; expected a codex managed_agent_id"
        ))
        .into());
    }
    if state.acp_agent_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is an ACP managed agent; expected a codex managed_agent_id"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!(
        "managed agent '{agent_id}' not found; expected managed_agent_id"
    ))
    .into())
}

pub(crate) fn ensure_acp_agent(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    if state.acp_agent_manager.get(agent_id).is_ok() {
        return Ok(());
    }
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a terminal managed agent; expected an ACP managed_agent_id"
        ))
        .into());
    }
    if state.codex_controller.run(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a codex thread; expected an ACP managed_agent_id"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!(
        "managed agent '{agent_id}' not found; expected managed_agent_id"
    ))
    .into())
}
