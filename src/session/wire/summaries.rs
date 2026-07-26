//! Session wire aggregates served by the daemon's session endpoints.
//!
//! These describe the session domain, so they live with it and the daemon
//! re-exports them from `crate::daemon::protocol`. The diagnostics, telemetry
//! and timeline-window clusters stay in the daemon: they describe the daemon
//! itself and reach for its manifest, launch-agent and GitHub status types.

use serde::{Deserialize, Serialize};

use crate::hooks::protocol::payloads::AskUserQuestionPrompt;
use crate::observe::types::{FixSafety, IssueCategory, IssueCode, IssueSeverity};
use crate::session::types::AgentRegistrationWire;
use crate::session::types::{
    AgentRegistration, PendingLeaderTransfer, SessionMetrics, SessionSignalRecord, SessionStatus,
    WorkItem,
};
use harness_protocol::timeline::TimelineEntry;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct WorktreeSummary {
    pub checkout_id: String,
    pub name: String,
    pub checkout_root: String,
    pub context_root: String,
    pub active_session_count: usize,
    pub total_session_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub struct SessionSummary {
    pub project_id: String,
    pub project_name: String,
    pub project_dir: Option<String>,
    pub context_root: String,
    pub worktree_path: String,
    pub shared_path: String,
    pub origin_path: String,
    pub branch_ref: String,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_origin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adopted_at: Option<String>,
    pub metrics: SessionMetrics,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
    pub agent_sessions: Vec<ObserverAgentSessionSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub struct ObserverActiveWorker {
    pub issue_id: String,
    pub target_file: String,
    pub started_at: String,
    pub agent_id: Option<String>,
    pub runtime: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct ObserverAgentSessionSummary {
    pub agent_id: String,
    pub runtime: String,
    pub log_path: Option<String>,
    pub cursor: usize,
    pub last_activity: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[derive(utoipa::ToSchema)]
pub struct AgentPendingUserPrompt {
    pub tool_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_since: Option<String>,
    #[serde(default)]
    pub questions: Vec<AskUserQuestionPrompt>,
    /// Compatibility summary for clients that still expect a single-line prompt
    /// message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct AgentToolActivitySummary {
    pub agent_id: String,
    pub runtime: String,
    pub tool_invocation_count: usize,
    pub tool_result_count: usize,
    pub tool_error_count: usize,
    pub latest_tool_name: Option<String>,
    pub latest_event_at: Option<String>,
    pub recent_tools: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_user_prompt: Option<AgentPendingUserPrompt>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct SessionDetail {
    pub session: SessionSummary,
    #[schema(value_type = Vec<AgentRegistrationWire>)]
    pub agents: Vec<AgentRegistration>,
    pub tasks: Vec<WorkItem>,
    pub signals: Vec<SessionSignalRecord>,
    pub observer: Option<ObserverSummary>,
    pub agent_activity: Vec<AgentToolActivitySummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionsUpdatedPayload {
    pub projects: Vec<ProjectSummary>,
    pub sessions: Vec<SessionSummary>,
}

/// Incremental session-index update emitted after a single-session mutation.
///
/// Carries only the sessions that changed plus the IDs of any that were
/// removed, instead of the full session list in [`SessionsUpdatedPayload`].
/// Clients merge it into their cached index: upsert each `changed` summary by
/// `session_id`, drop each `removed` ID, and replace the project list. The
/// periodic full `sessions_updated` from the watch loop remains the baseline
/// that any missed delta self-heals against.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionsUpdatedDeltaPayload {
    pub changed: Vec<SessionSummary>,
    pub removed: Vec<String>,
    pub projects: Vec<ProjectSummary>,
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
