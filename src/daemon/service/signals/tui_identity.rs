use super::AgentRegistration;
use crate::session::types::ManagedAgentKind;

pub(crate) fn managed_tui_id_for_registration(agent: &AgentRegistration) -> Option<&str> {
    match agent.managed_agent.as_ref() {
        Some(managed_agent) if managed_agent.kind == ManagedAgentKind::Tui => {
            if managed_agent.id.trim().is_empty() {
                None
            } else {
                Some(managed_agent.id.as_str())
            }
        }
        _ => None,
    }
}

pub(crate) fn legacy_capability_tui_id_for_registration(agent: &AgentRegistration) -> Option<&str> {
    agent.capabilities.iter().find_map(|capability| {
        capability
            .strip_prefix("agent-tui:")
            .filter(|value| !value.trim().is_empty())
    })
}

pub(crate) fn legacy_compatible_tui_id_for_signal_delivery(
    agent: &AgentRegistration,
) -> Option<&str> {
    if let Some(tui_id) = managed_tui_id_for_registration(agent) {
        return Some(tui_id);
    }

    legacy_capability_tui_id_for_registration(agent).inspect(|legacy_tui_id| {
        log_legacy_tui_identity(agent, legacy_tui_id);
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_legacy_tui_identity(agent: &AgentRegistration, legacy_tui_id: &str) {
    tracing::warn!(
        session_agent_id = %agent.agent_id,
        runtime = %agent.runtime,
        legacy_tui_id,
        "using legacy capability-derived TUI identity for active signal delivery"
    );
}
