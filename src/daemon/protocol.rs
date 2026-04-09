use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::launchd::LaunchAgentStatus;
use super::state::{DaemonAuditEvent, DaemonDiagnostics, DaemonManifest};
use crate::agents::runtime::signal::AckResult;
use crate::observe::types::{FixSafety, IssueCategory, IssueCode, IssueSeverity};
use crate::session::types::{
    AgentRegistration, PendingLeaderTransfer, SessionMetrics, SessionRole, SessionSignalRecord,
    SessionState, SessionStatus, TaskSeverity, TaskStatus, WorkItem,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub pid: u32,
    pub endpoint: String,
    pub started_at: String,
    pub log_level: String,
    pub project_count: usize,
    pub worktree_count: usize,
    pub session_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonControlResponse {
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogLevelResponse {
    pub level: String,
    pub filter: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetLogLevelRequest {
    pub level: String,
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
pub struct WorktreeSummary {
    pub checkout_id: String,
    pub name: String,
    pub checkout_root: String,
    pub context_root: String,
    pub active_session_count: usize,
    pub total_session_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSummary {
    pub project_id: String,
    pub name: String,
    pub project_dir: Option<String>,
    pub context_root: String,
    pub active_session_count: usize,
    pub total_session_count: usize,
    pub worktrees: Vec<WorktreeSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub project_id: String,
    pub project_name: String,
    pub project_dir: Option<String>,
    pub context_root: String,
    pub checkout_id: String,
    pub checkout_root: String,
    pub is_worktree: bool,
    pub worktree_name: Option<String>,
    pub session_id: String,
    pub title: String,
    pub context: String,
    pub status: SessionStatus,
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: Option<String>,
    pub leader_id: Option<String>,
    pub observe_id: Option<String>,
    pub pending_leader_transfer: Option<PendingLeaderTransfer>,
    pub metrics: SessionMetrics,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverSummary {
    pub observe_id: String,
    pub last_scan_time: String,
    pub open_issue_count: usize,
    pub resolved_issue_count: usize,
    pub muted_code_count: usize,
    pub active_worker_count: usize,
    pub open_issues: Vec<ObserverOpenIssue>,
    pub muted_codes: Vec<IssueCode>,
    pub active_workers: Vec<ObserverActiveWorker>,
    pub cycle_history: Vec<ObserverCycleSummary>,
    pub agent_sessions: Vec<ObserverAgentSessionSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverOpenIssue {
    pub issue_id: String,
    pub code: IssueCode,
    pub severity: IssueSeverity,
    pub category: IssueCategory,
    pub summary: String,
    pub fingerprint: String,
    pub first_seen_line: usize,
    pub occurrence_count: usize,
    pub last_seen_line: usize,
    pub fix_safety: FixSafety,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverActiveWorker {
    pub issue_id: String,
    pub target_file: String,
    pub started_at: String,
    pub agent_id: Option<String>,
    pub runtime: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverCycleSummary {
    pub timestamp: String,
    pub from_line: usize,
    pub to_line: usize,
    pub new_issues: usize,
    pub resolved: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverAgentSessionSummary {
    pub agent_id: String,
    pub runtime: String,
    pub log_path: Option<String>,
    pub cursor: usize,
    pub last_activity: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentToolActivitySummary {
    pub agent_id: String,
    pub runtime: String,
    pub tool_invocation_count: usize,
    pub tool_result_count: usize,
    pub tool_error_count: usize,
    pub latest_tool_name: Option<String>,
    pub latest_event_at: Option<String>,
    pub recent_tools: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionDetail {
    pub session: SessionSummary,
    pub agents: Vec<AgentRegistration>,
    pub tasks: Vec<WorkItem>,
    pub signals: Vec<SessionSignalRecord>,
    pub observer: Option<ObserverSummary>,
    pub agent_activity: Vec<AgentToolActivitySummary>,
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
pub struct ReadyEventPayload {
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionsUpdatedPayload {
    pub projects: Vec<ProjectSummary>,
    pub sessions: Vec<SessionSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionUpdatedPayload {
    pub detail: SessionDetail,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeline: Option<Vec<TimelineEntry>>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub extensions_pending: bool,
}

/// Deferred session detail extensions pushed after a `scope: "core"` request.
///
/// Contains the expensive-to-compute fields that are omitted from the core
/// session detail response: signals, observer snapshot, and agent activity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionExtensionsPayload {
    pub session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signals: Option<Vec<SessionSignalRecord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observer: Option<ObserverSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_activity: Option<Vec<AgentToolActivitySummary>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamEvent {
    pub event: String,
    pub recorded_at: String,
    pub session_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexRunMode {
    Report,
    WorkspaceWrite,
    Approval,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexRunStatus {
    Queued,
    Running,
    WaitingApproval,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexApprovalDecision {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    pub prompt: String,
    pub mode: CodexRunMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_thread_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexSteerRequest {
    pub prompt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalDecisionRequest {
    pub decision: CodexApprovalDecision,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunListResponse {
    pub runs: Vec<CodexRunSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalRequest {
    pub approval_id: String,
    pub request_id: String,
    pub kind: String,
    pub title: String,
    pub detail: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub cwd: Option<String>,
    pub command: Option<String>,
    pub file_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunSnapshot {
    pub run_id: String,
    pub session_id: String,
    pub project_dir: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub mode: CodexRunMode,
    pub status: CodexRunStatus,
    pub prompt: String,
    pub latest_summary: Option<String>,
    pub final_message: Option<String>,
    pub error: Option<String>,
    pub pending_approvals: Vec<CodexApprovalRequest>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalRequestedPayload {
    pub run: CodexRunSnapshot,
    pub approval: CodexApprovalRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoleChangeRequest {
    pub actor: String,
    pub role: SessionRole,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRemoveRequest {
    pub actor: String,
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
    pub suggested_fix: Option<String>,
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

// --- Daemon-first session mutation requests ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStartRequest {
    #[serde(default)]
    pub title: String,
    pub context: String,
    pub runtime: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub project_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionJoinRequest {
    pub runtime: String,
    pub role: SessionRole,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub project_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalAckRequest {
    pub agent_id: String,
    pub signal_id: String,
    pub result: AckResult,
    pub project_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMutationResponse {
    pub state: SessionState,
}

// --- WebSocket wire protocol ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsRequest {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsResponse {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<WsErrorPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsErrorPayload {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub details: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsPushEvent {
    pub event: String,
    pub recorded_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub payload: Value,
    pub seq: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn session_start_request_round_trips() {
        let request = SessionStartRequest {
            title: "auth fix session".into(),
            context: "fix auth bug".into(),
            runtime: "claude".into(),
            session_id: Some("my-session".into()),
            project_dir: "/tmp/project".into(),
        };
        let json = serde_json::to_value(&request).expect("serialize");
        assert_eq!(json["title"], "auth fix session");
        assert_eq!(json["context"], "fix auth bug");
        assert_eq!(json["runtime"], "claude");
        assert_eq!(json["session_id"], "my-session");
        assert_eq!(json["project_dir"], "/tmp/project");

        let back: SessionStartRequest = serde_json::from_value(json).expect("deserialize");
        assert_eq!(back.title, "auth fix session");
        assert_eq!(back.context, "fix auth bug");
        assert_eq!(back.session_id.as_deref(), Some("my-session"));
    }

    #[test]
    fn session_start_request_optional_session_id() {
        let json = json!({
            "context": "goal",
            "runtime": "codex",
            "project_dir": "/tmp/p"
        });
        let request: SessionStartRequest = serde_json::from_value(json).expect("deserialize");
        assert!(request.session_id.is_none());

        let serialized = serde_json::to_value(&request).expect("serialize");
        assert!(serialized.get("session_id").is_none());
    }

    #[test]
    fn session_join_request_round_trips() {
        let request = SessionJoinRequest {
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            name: Some("codex worker".into()),
            project_dir: "/tmp/project".into(),
        };
        let json = serde_json::to_value(&request).expect("serialize");
        assert_eq!(json["role"], "worker");

        let back: SessionJoinRequest = serde_json::from_value(json).expect("deserialize");
        assert_eq!(back.runtime, "codex");
        assert_eq!(back.role, SessionRole::Worker);
        assert_eq!(back.capabilities, vec!["general"]);
    }

    #[test]
    fn session_join_request_defaults_empty_capabilities() {
        let json = json!({
            "runtime": "claude",
            "role": "observer",
            "project_dir": "/tmp/p"
        });
        let request: SessionJoinRequest = serde_json::from_value(json).expect("deserialize");
        assert!(request.capabilities.is_empty());
        assert!(request.name.is_none());
    }

    #[test]
    fn signal_ack_request_round_trips() {
        let request = SignalAckRequest {
            agent_id: "codex-worker".into(),
            signal_id: "sig-123".into(),
            result: AckResult::Accepted,
            project_dir: "/tmp/project".into(),
        };
        let json = serde_json::to_value(&request).expect("serialize");
        assert_eq!(json["result"], "accepted");

        let back: SignalAckRequest = serde_json::from_value(json).expect("deserialize");
        assert_eq!(back.result, AckResult::Accepted);
    }

    #[test]
    fn session_mutation_response_contains_state() {
        let json = json!({
            "state": {
                "schema_version": 3,
                "state_version": 1,
                "session_id": "sess-1",
                "context": "test",
                "status": "active",
                "created_at": "2024-01-01T00:00:00Z",
                "updated_at": "2024-01-01T00:00:00Z",
                "agents": {},
                "tasks": {},
                "metrics": {
                    "agent_count": 0,
                    "active_agent_count": 0,
                    "open_task_count": 0,
                    "in_progress_task_count": 0,
                    "blocked_task_count": 0,
                    "completed_task_count": 0
                }
            }
        });
        let response: SessionMutationResponse = serde_json::from_value(json).expect("deserialize");
        assert_eq!(response.state.session_id, "sess-1");
    }
}
