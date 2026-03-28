use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::launchd::LaunchAgentStatus;
use super::state::{DaemonAuditEvent, DaemonDiagnostics, DaemonManifest};
use crate::session::types::{
    AgentRegistration, SessionMetrics, SessionRole, SessionSignalRecord, SessionStatus,
    TaskSeverity, TaskStatus, WorkItem,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub pid: u32,
    pub endpoint: String,
    pub started_at: String,
    pub project_count: usize,
    pub session_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonDiagnosticsReport {
    pub health: Option<HealthResponse>,
    pub manifest: Option<DaemonManifest>,
    pub launch_agent: LaunchAgentStatus,
    pub workspace: DaemonDiagnostics,
    pub recent_events: Vec<DaemonAuditEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSummary {
    pub project_id: String,
    pub name: String,
    pub project_dir: Option<String>,
    pub context_root: String,
    pub active_session_count: usize,
    pub total_session_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub project_id: String,
    pub project_name: String,
    pub project_dir: Option<String>,
    pub context_root: String,
    pub session_id: String,
    pub context: String,
    pub status: SessionStatus,
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: Option<String>,
    pub leader_id: Option<String>,
    pub observe_id: Option<String>,
    pub metrics: SessionMetrics,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverSummary {
    pub observe_id: String,
    pub last_scan_time: String,
    pub open_issue_count: usize,
    pub muted_code_count: usize,
    pub active_worker_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionDetail {
    pub session: SessionSummary,
    pub agents: Vec<AgentRegistration>,
    pub tasks: Vec<WorkItem>,
    pub signals: Vec<SessionSignalRecord>,
    pub observer: Option<ObserverSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineEntry {
    pub entry_id: String,
    pub recorded_at: String,
    pub kind: String,
    pub session_id: String,
    pub agent_id: Option<String>,
    pub task_id: Option<String>,
    pub summary: String,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamEvent {
    pub event: String,
    pub recorded_at: String,
    pub session_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoleChangeRequest {
    pub actor: String,
    pub role: SessionRole,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeaderTransferRequest {
    pub actor: String,
    pub new_leader_id: String,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCreateRequest {
    pub actor: String,
    pub title: String,
    pub context: Option<String>,
    pub severity: TaskSeverity,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskAssignRequest {
    pub actor: String,
    pub agent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskUpdateRequest {
    pub actor: String,
    pub status: TaskStatus,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCheckpointRequest {
    pub actor: String,
    pub summary: String,
    pub progress: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEndRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalSendRequest {
    pub actor: String,
    pub agent_id: String,
    pub command: String,
    pub message: String,
    pub action_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserveSessionRequest {
    pub actor: Option<String>,
}
