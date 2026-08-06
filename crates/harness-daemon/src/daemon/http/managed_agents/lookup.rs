use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::session::ManagedAgentKind;

use super::super::DaemonHttpState;
use super::run_terminal_agent_blocking;

pub(crate) async fn locate_managed_agent_kind(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<ManagedAgentKind, CliError> {
    let terminal_id = agent_id.to_string();
    let terminal = runtime_present(
        run_terminal_agent_blocking(state, "locate terminal agent", move |manager| {
            manager.get(&terminal_id)
        })
        .await,
    )?;
    let codex = runtime_present(state.codex_controller.run(agent_id))?;
    let acp = runtime_present(state.acp_agent_manager.get(agent_id))?;
    resolve_managed_agent_kind(agent_id, terminal, codex, acp)
}

fn runtime_present<T>(result: Result<T, CliError>) -> Result<bool, CliError> {
    match result {
        Ok(_) => Ok(true),
        Err(error) if error.code() == "KSRCLI090" => Ok(false),
        Err(error) => Err(error),
    }
}

fn resolve_managed_agent_kind(
    agent_id: &str,
    terminal: bool,
    codex: bool,
    acp: bool,
) -> Result<ManagedAgentKind, CliError> {
    let matches = [
        terminal.then_some(ManagedAgentKind::Tui),
        codex.then_some(ManagedAgentKind::Codex),
        acp.then_some(ManagedAgentKind::Acp),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();
    match matches.as_slice() {
        [kind] => Ok(*kind),
        [] => Err(CliErrorKind::session_not_active(format!(
            "managed agent '{agent_id}' not found; expected managed_agent_id"
        ))
        .into()),
        _ => Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent id '{agent_id}' exists in multiple runtime families; provide managed_agent_kind"
        ))
        .into()),
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualified_lookup_accepts_each_single_runtime_family() {
        assert_eq!(
            resolve_managed_agent_kind("same", true, false, false).expect("terminal"),
            ManagedAgentKind::Tui
        );
        assert_eq!(
            resolve_managed_agent_kind("same", false, true, false).expect("Codex"),
            ManagedAgentKind::Codex
        );
        assert_eq!(
            resolve_managed_agent_kind("same", false, false, true).expect("ACP"),
            ManagedAgentKind::Acp
        );
    }

    #[test]
    fn qualified_lookup_rejects_cross_family_ambiguity() {
        let error =
            resolve_managed_agent_kind("same", true, true, false).expect_err("ambiguous native id");
        assert_eq!(error.code(), "KSRCLI092");
    }

    #[test]
    fn qualified_lookup_preserves_non_absence_errors() {
        let error = CliError::from(CliErrorKind::workflow_io("manager unavailable"));
        let returned = runtime_present::<()>(Err(error)).expect_err("manager error");
        assert_eq!(returned.code(), "WORKFLOW_IO");
    }
}
