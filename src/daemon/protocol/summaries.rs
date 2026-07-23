use serde::{Deserialize, Serialize};
use serde_json::Value;

#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
use crate::agents::acp::probe::AcpRuntimeProbeResponse;
use crate::daemon::launchd::LaunchAgentStatus;
use crate::daemon::state::{DaemonAuditEvent, DaemonDiagnostics, DaemonManifest};
use crate::github_api::{GitHubApiStatus, GitHubRateResource};
use crate::hooks::protocol::payloads::AskUserQuestionPrompt;
use crate::observe::types::{FixSafety, IssueCategory, IssueCode, IssueSeverity};
use crate::session::service::ResolvedRuntimeSessionAgent;
use crate::session::types::{
    AgentRegistration, PendingLeaderTransfer, SessionMetrics, SessionSignalRecord, SessionStatus,
    WorkItem,
};
#[cfg(not(any(feature = "bridge-runtime", feature = "daemon-runtime")))]
use harness_protocol::managed_agents::acp::AcpRuntimeProbeResponse;

/// Daemon HTTP/WS wire-protocol version. Increment on a breaking schema
/// change so the Mac app can detect version skew on connect.
pub const DAEMON_WIRE_VERSION: u32 = 2;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
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
    #[serde(default = "default_wire_version")]
    pub wire_version: u32,
}

fn default_wire_version() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
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
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
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
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct RuntimeSessionResolutionResponse {
    pub resolved: Option<ResolvedRuntimeSessionAgent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct LogLevelResponse {
    pub level: String,
    pub filter: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub enum DaemonTelemetryKind {
    DecodeFailure,
}

impl DaemonTelemetryKind {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::DecodeFailure => "decode_failure",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct DaemonTelemetryRequest {
    pub kind: DaemonTelemetryKind,
    pub source: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct DaemonTelemetryResponse {
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonDiagnosticsReport {
    pub health: Option<HealthResponse>,
    pub manifest: Option<DaemonManifest>,
    pub launch_agent: LaunchAgentStatus,
    pub acp_runtime_probe: AcpRuntimeProbeResponse,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_api: Option<GitHubApiDiagnostics>,
    pub workspace: DaemonDiagnostics,
    pub recent_events: Vec<DaemonAuditEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubApiDiagnostics {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_revision: Option<u64>,
    pub buckets: Vec<GitHubRateBucketDiagnostics>,
    pub cooling: Vec<GitHubCooldownDiagnostics>,
    pub last_hour_network_requests: u64,
    pub last_hour_graphql_points: u64,
    pub cache_hits: u64,
    pub cache_stale_hits: u64,
    pub cache_deferred_hits: u64,
    pub deferred_budget: u64,
    pub top_operations: Vec<GitHubOperationSpendDiagnostics>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubRateBucketDiagnostics {
    pub resource: String,
    pub remaining: u32,
    pub limit: u32,
    pub used: u32,
    pub reset_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubCooldownDiagnostics {
    pub resource: String,
    pub reason: String,
    pub until_seconds_from_now: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubOperationSpendDiagnostics {
    pub operation: String,
    pub network_requests: u64,
    pub graphql_points: u64,
}

impl From<GitHubApiStatus> for GitHubApiDiagnostics {
    fn from(status: GitHubApiStatus) -> Self {
        Self {
            data_revision: Some(status.data_revision),
            buckets: status
                .buckets
                .into_iter()
                .map(|bucket| GitHubRateBucketDiagnostics {
                    resource: github_resource_name(bucket.resource),
                    remaining: bucket.remaining,
                    limit: bucket.limit,
                    used: bucket.used,
                    reset_at: bucket.reset_at,
                })
                .collect(),
            cooling: status
                .cooling
                .into_iter()
                .map(|cooldown| GitHubCooldownDiagnostics {
                    resource: github_resource_name(cooldown.resource),
                    reason: cooldown.reason,
                    until_seconds_from_now: cooldown.until_seconds_from_now,
                })
                .collect(),
            last_hour_network_requests: status.last_hour_network_requests,
            last_hour_graphql_points: status.last_hour_graphql_points,
            cache_hits: status.cache_hits,
            cache_stale_hits: status.cache_stale_hits,
            cache_deferred_hits: status.cache_deferred_hits,
            deferred_budget: status.deferred_budget,
            top_operations: status
                .top_operations
                .into_iter()
                .map(|operation| GitHubOperationSpendDiagnostics {
                    operation: operation.operation,
                    network_requests: operation.network_requests,
                    graphql_points: operation.graphql_points,
                })
                .collect(),
        }
    }
}

fn github_resource_name(resource: GitHubRateResource) -> String {
    serde_json::to_value(resource)
        .ok()
        .and_then(|value| value.as_str().map(ToString::to_string))
        .unwrap_or_else(|| format!("{resource:?}"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct WorktreeSummary {
    pub checkout_id: String,
    pub name: String,
    pub checkout_root: String,
    pub context_root: String,
    pub active_session_count: usize,
    pub total_session_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
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
pub struct ObserverAgentSessionSummary {
    pub agent_id: String,
    pub runtime: String,
    pub log_path: Option<String>,
    pub cursor: usize,
    pub last_activity: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
pub struct AcpTranscriptResponse {
    pub entries: Vec<TimelineEntry>,
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

pub use harness_protocol::daemon::StreamEvent;
