use super::AcpAgentManagerHandle;

pub(super) fn rollback_registration_best_effort(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
    agent_id: &str,
    reason_label: &str,
) {
    manager.rollback_orchestration_registration_best_effort(
        session_id,
        acp_id,
        agent_id,
        reason_label,
    );
}
