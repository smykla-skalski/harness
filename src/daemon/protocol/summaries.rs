use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::daemon::launchd::LaunchAgentStatus;
use crate::daemon::state::{DaemonAuditEvent, DaemonDiagnostics, DaemonManifest};
use crate::observe::types::{FixSafety, IssueCategory, IssueCode, IssueSeverity};
use crate::session::types::{
    AgentRegistration, PendingLeaderTransfer, SessionMetrics, SessionSignalRecord, SessionStatus,
    WorkItem,
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

/// Lightweight readiness probe response.
///
/// Returned by `GET /v1/ready`. Confirms the daemon is serving HTTP, the
/// caller is authenticated, and the backing storage slot is wired up - but
/// intentionally avoids any database query so short-lived CLI invocations can
/// verify readiness cheaply.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadinessResponse {
    pub ready: bool,
    pub daemon_epoch: String,
}

/// Wire-level outcome of a runtime-session lookup.
///
/// Returned by `GET /v1/runtime-sessions/resolve`. `resolved` is `None` when
/// no live agent matches; `Some` carries the single unambiguous match. The
/// daemon surfaces ambiguity as a `session_ambiguous` error instead of
/// populating this response with multiple entries.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeSessionResolutionResponse {
    pub resolved: Option<crate::session::service::ResolvedRuntimeSessionAgent>,
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
pub struct HostBridgeReconfigureRequest {
    #[serde(default)]
    pub enable: Vec<String>,
    #[serde(default)]
    pub disable: Vec<String>,
    #[serde(default)]
    pub force: bool,
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
    pub evidence_excerpt: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TimelineCursor {
    pub recorded_at: String,
    pub entry_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct TimelineWindowRequest {
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub before: Option<TimelineCursor>,
    #[serde(default)]
    pub after: Option<TimelineCursor>,
    #[serde(default)]
    pub known_revision: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineWindowResponse {
    pub revision: i64,
    pub total_count: usize,
    pub window_start: usize,
    pub window_end: usize,
    pub has_older: bool,
    pub has_newer: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oldest_cursor: Option<TimelineCursor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub newest_cursor: Option<TimelineCursor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<TimelineEntry>>,
    pub unchanged: bool,
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
