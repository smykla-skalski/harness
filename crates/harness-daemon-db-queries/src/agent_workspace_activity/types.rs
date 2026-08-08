use harness_protocol::agent::AckResult;
use harness_protocol::daemon::activity::AgentWorkspaceSignalRecord;

#[derive(Debug, Clone)]
pub struct AgentWorkspaceSignalAcknowledgment {
    pub signal_id: String,
    pub result: AckResult,
    pub details: Option<String>,
    pub acknowledged_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AgentWorkspaceSignalRoute {
    pub workspace_id: String,
    pub member_id: String,
    pub signal_id: String,
    pub runtime: String,
    pub runtime_session_id: String,
    pub project_dir: String,
    pub source_session_id: String,
    pub source_agent_id: String,
}

#[derive(Debug, Clone)]
pub struct AgentWorkspaceSignalTarget {
    pub workspace_id: String,
    pub member_id: String,
    pub runtime: String,
    pub managed_agent_kind: String,
    pub managed_agent_id: String,
    pub runtime_session_id: Option<String>,
    pub project_dir: String,
    pub source_session_id: Option<String>,
    pub source_agent_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AgentWorkspaceSignalInsertion {
    pub record: AgentWorkspaceSignalRecord,
    pub inserted: bool,
}
