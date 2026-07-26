use serde::{Deserialize, Serialize};

#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
use crate::agents::acp::probe::AcpRuntimeProbeResponse;
use crate::daemon::launchd::LaunchAgentStatus;
use crate::daemon::state::{DaemonAuditEvent, DaemonDiagnostics, DaemonManifest};
use crate::github_api::{GitHubApiStatus, GitHubRateResource};
use crate::session::service::ResolvedRuntimeSessionAgent;
#[cfg(not(any(feature = "bridge-runtime", feature = "daemon-runtime")))]
use harness_protocol::managed_agents::acp::AcpRuntimeProbeResponse;

/// Daemon HTTP/WS wire-protocol version. Increment on a breaking schema
/// change so the Mac app can detect version skew on connect.
///
/// v4 dropped `todoist` from the external-provider values. A daemon that
/// predates the removal still serves it out of an unmigrated database, and the
/// app's decoder rejects an unknown provider outright, so the skew has to be
/// caught at connect rather than surfacing as a failed decode.
pub const DAEMON_WIRE_VERSION: u32 = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
    /// Stable identity of the daemon answering, unchanged by restarts,
    /// upgrades, and endpoint changes. Empty from daemons predating the field.
    #[serde(default)]
    pub daemon_id: String,
    /// Operator-facing name for the same daemon. Not unique.
    #[serde(default)]
    pub daemon_name: String,
}

fn default_wire_version() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub struct RuntimeSessionResolutionResponse {
    pub resolved: Option<ResolvedRuntimeSessionAgent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct LogLevelResponse {
    pub level: String,
    pub filter: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct SetLogLevelRequest {
    pub level: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub struct DaemonTelemetryRequest {
    pub kind: DaemonTelemetryKind,
    pub source: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct DaemonTelemetryResponse {
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub struct GitHubRateBucketDiagnostics {
    pub resource: String,
    pub remaining: u32,
    pub limit: u32,
    pub used: u32,
    pub reset_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct GitHubCooldownDiagnostics {
    pub resource: String,
    pub reason: String,
    pub until_seconds_from_now: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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


pub use harness_protocol::timeline::TimelineEntry;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
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
#[derive(utoipa::ToSchema)]
pub struct AcpTranscriptResponse {
    pub entries: Vec<TimelineEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadyEventPayload {
    pub ok: bool,
}


pub use harness_protocol::daemon::StreamEvent;
