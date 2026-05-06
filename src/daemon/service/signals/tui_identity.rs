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
