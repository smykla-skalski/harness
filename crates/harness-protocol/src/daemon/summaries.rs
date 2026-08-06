//! Daemon health, readiness, log-level, telemetry, and ACP-transcript wire
//! types. Relocated from `harness-daemon`'s `daemon::protocol::summaries`,
//! which kept the daemon-state-carrying remainder (the diagnostics report and
//! its GitHub rate-limit fields) plus the timeline pagination types tracked
//! separately by issue #1102.

use serde::{Deserialize, Serialize};

use crate::timeline::TimelineEntry;

/// Which store currently owns orchestration mutations for a durable workspace.
///
/// Workspace identity is already durable when this is `LegacySession`; only the
/// still-unmigrated orchestration domains continue to use the selected Session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AgentWorkspaceOrchestrationAuthority {
    NoOwner,
    LegacySession,
    Workspace,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AgentWorkspaceAvailability {
    Available,
    MissingWorktree,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AgentWorkspaceConflictKind {
    ActiveOwnerCollision,
    MalformedCandidate,
    SourceDisagreement,
}

/// Provenance retained beside the durable workspace identity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceProvenance {
    pub daemon_id: String,
    pub project_scope_id: String,
    pub checkout_id: String,
    pub source_project_id: String,
    #[serde(default)]
    pub legacy_session_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_legacy_session_id: Option<String>,
    pub manifest_digest: String,
}

/// Durable agent workspace exposed to clients independently of Session identity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceSummary {
    pub workspace_id: String,
    pub project_name: String,
    pub checkout_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkout_root: Option<String>,
    pub context_root: String,
    pub is_worktree: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_name: Option<String>,
    pub availability: AgentWorkspaceAvailability,
    pub orchestration_authority: AgentWorkspaceOrchestrationAuthority,
    pub provenance: AgentWorkspaceProvenance,
    pub created_at: String,
    pub updated_at: String,
}

/// A collision or malformed source that kept legacy ownership authoritative.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceConflict {
    pub daemon_id: String,
    pub project_scope_id: String,
    pub checkout_id: String,
    pub kind: AgentWorkspaceConflictKind,
    pub legacy_session_ids: Vec<String>,
    pub detail: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceListResponse {
    pub workspaces: Vec<AgentWorkspaceSummary>,
    pub conflicts: Vec<AgentWorkspaceConflict>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonControlResponse {
    pub status: String,
}

/// Lightweight readiness probe response.
///
/// Returned by `GET /v1/ready`. Confirms the daemon is serving HTTP, the
/// caller is authenticated, and the backing storage slot is wired up - but
/// intentionally avoids any database query so short-lived CLI invocations can
/// verify readiness cheaply.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReadinessResponse {
    pub ready: bool,
    pub daemon_epoch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct LogLevelResponse {
    pub level: String,
    pub filter: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct SetLogLevelRequest {
    pub level: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonTelemetryRequest {
    pub kind: DaemonTelemetryKind,
    pub source: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonTelemetryResponse {
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AcpTranscriptResponse {
    pub entries: Vec<TimelineEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadyEventPayload {
    pub ok: bool,
}
