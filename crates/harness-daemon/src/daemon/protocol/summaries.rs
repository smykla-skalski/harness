use serde::{Deserialize, Serialize};

#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
use crate::agents::acp::probe::AcpRuntimeProbeResponse;
use crate::daemon::launchd::LaunchAgentStatus;
use crate::daemon::state::{DaemonAuditEvent, DaemonDiagnostics, DaemonManifest};
use crate::github_api::{GitHubApiStatus, GitHubRateResource};
#[cfg(not(any(feature = "bridge-runtime", feature = "daemon-runtime")))]
use harness_protocol::managed_agents::acp::AcpRuntimeProbeResponse;

use harness_protocol::daemon::summaries::HealthResponse;

pub use harness_protocol::session_wire::RuntimeSessionResolutionResponse;

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct GitHubRateBucketDiagnostics {
    pub resource: String,
    pub remaining: u32,
    pub limit: u32,
    pub used: u32,
    pub reset_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct GitHubCooldownDiagnostics {
    pub resource: String,
    pub reason: String,
    pub until_seconds_from_now: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
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

// TimelineCursor, TimelineWindowRequest, and TimelineWindowResponse live in
// harness_protocol::timeline alongside TimelineEntry; import them from there
// directly instead of adding a re-export here.
pub use harness_protocol::timeline::TimelineEntry;

pub use harness_protocol::daemon::StreamEvent;
