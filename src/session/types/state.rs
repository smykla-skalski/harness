use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::{
    ARBITRATION_BLOCKED_REASON, AgentRegistration, AgentStatus, HarnessSessionId, ManagedAgentRef,
    PendingLeaderTransfer, RuntimeSessionId, SessionAgentId, SessionPolicy, TaskStatus, WorkItem,
};

/// Current schema version for session state files.
pub const CURRENT_VERSION: u32 = 14;

/// Server-derived principal for daemon-authenticated control-plane mutations.
///
/// Local monitor clients authenticate with a shared bearer token, while remote
/// clients authenticate with per-client credentials. HTTP and websocket
/// request payloads must not treat client-supplied actor IDs as authenticated.
/// Daemon transports rebind actor-bearing mutations server-side.
pub const CONTROL_PLANE_ACTOR_ID: &str = "harness-app";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RemoteControlPlaneActor {
    client_id: String,
    platform: String,
    role: String,
    scopes: Vec<String>,
}

/// Recognize a transport-bound local or write-capable remote control-plane actor.
/// Untrusted payload actors must be rebound before reaching this check.
#[must_use]
pub(crate) fn is_control_plane_actor_id(actor_id: &str) -> bool {
    if actor_id == CONTROL_PLANE_ACTOR_ID {
        return true;
    }
    if !actor_id.starts_with('{') || !actor_id.ends_with('}') {
        return false;
    }
    serde_json::from_str::<RemoteControlPlaneActor>(actor_id).is_ok_and(|actor| {
        let has_control_scope = match actor.role.as_str() {
            "admin" => actor
                .scopes
                .iter()
                .any(|scope| matches!(scope.as_str(), "write" | "admin")),
            "operator" => actor.scopes.iter().any(|scope| scope == "write"),
            _ => false,
        };
        !actor.client_id.trim().is_empty()
            && !actor.platform.trim().is_empty()
            && has_control_scope
            && actor
                .scopes
                .iter()
                .all(|scope| matches!(scope.as_str(), "read" | "write" | "admin"))
    })
}

/// Main versioned state document for a multi-agent orchestration session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub schema_version: u32,
    /// Monotonically increasing counter for optimistic concurrency.
    #[serde(default)]
    pub state_version: u64,
    pub session_id: String,
    /// Canonicalized directory-component name (matches `SessionLayout::project_name`).
    #[serde(default)]
    pub project_name: String,
    /// Per-session worktree directory (`<sessions_root>/<project>/<sid>/workspace`).
    #[serde(default)]
    pub worktree_path: PathBuf,
    /// Per-session shared directory for cross-agent artefacts.
    #[serde(default)]
    pub shared_path: PathBuf,
    /// User's original repository root (pre-worktree).
    #[serde(default)]
    pub origin_path: PathBuf,
    /// Git branch owned by this session (`harness/<sid>`).
    #[serde(default)]
    pub branch_ref: String,
    /// Short human-readable session name.
    #[serde(default)]
    pub title: String,
    /// Human-readable session goal.
    pub context: String,
    pub status: SessionStatus,
    #[serde(default)]
    pub policy: SessionPolicy,
    pub created_at: String,
    pub updated_at: String,
    /// Registered agents keyed by agent ID.
    #[serde(default)]
    pub agents: BTreeMap<String, AgentRegistration>,
    /// Work items keyed by task ID.
    #[serde(default)]
    pub tasks: BTreeMap<String, WorkItem>,
    /// Agent ID of the current leader.
    #[serde(default)]
    pub leader_id: Option<String>,
    /// Timestamp when the session was archived.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_at: Option<String>,
    /// Most recent observed session activity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
    /// Observe state identifier associated with this session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observe_id: Option<String>,
    /// Pending leadership transfer request awaiting confirmation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_leader_transfer: Option<PendingLeaderTransfer>,
    /// Path of the external session directory this session was adopted from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_origin: Option<PathBuf>,
    /// Timestamp when this session was adopted from an external origin.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adopted_at: Option<String>,
    /// Cached counts for fast daemon and UI list rendering.
    #[serde(default)]
    pub metrics: SessionMetrics,
}

impl SessionState {
    #[must_use]
    pub fn harness_session_id(&self) -> HarnessSessionId {
        HarnessSessionId::from(self.session_id.as_str())
    }

    #[must_use]
    pub fn leader_session_agent_id(&self) -> Option<SessionAgentId> {
        self.leader_id.as_deref().map(SessionAgentId::from)
    }

    #[must_use]
    pub fn agent(&self, agent_id: &SessionAgentId) -> Option<&AgentRegistration> {
        self.agents.get(agent_id.as_str())
    }

    pub fn agent_mut(&mut self, agent_id: &SessionAgentId) -> Option<&mut AgentRegistration> {
        self.agents.get_mut(agent_id.as_str())
    }

    #[must_use]
    pub fn find_session_agent_id_by_managed_agent(
        &self,
        managed_agent: &ManagedAgentRef,
    ) -> Option<SessionAgentId> {
        self.agents
            .values()
            .find(|agent| agent.matches_managed_agent(managed_agent))
            .map(AgentRegistration::session_agent_id)
    }

    #[must_use]
    pub fn find_session_agent_id_by_runtime_session(
        &self,
        runtime_name: &str,
        runtime_session_id: &RuntimeSessionId,
    ) -> Option<SessionAgentId> {
        self.agents
            .values()
            .find(|agent| {
                agent.runtime == runtime_name
                    && agent
                        .matches_runtime_session_id(self.session_id.as_str(), runtime_session_id)
            })
            .map(AgentRegistration::session_agent_id)
    }
}

/// Session lifecycle status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    AwaitingLeader,
    Active,
    Paused,
    LeaderlessDegraded,
    Ended,
}

impl SessionStatus {
    #[must_use]
    pub const fn is_default_visible(self) -> bool {
        !matches!(self, Self::Ended)
    }

    #[must_use]
    pub const fn is_joinable(self) -> bool {
        matches!(
            self,
            Self::AwaitingLeader | Self::Active | Self::LeaderlessDegraded
        )
    }

    #[must_use]
    pub const fn allows_task_creation(self) -> bool {
        matches!(
            self,
            Self::AwaitingLeader | Self::Active | Self::LeaderlessDegraded
        )
    }

    #[must_use]
    pub const fn allows_end_session(self) -> bool {
        !matches!(self, Self::Ended)
    }

    #[must_use]
    pub const fn is_liveness_eligible(self) -> bool {
        matches!(
            self,
            Self::AwaitingLeader | Self::Active | Self::LeaderlessDegraded
        )
    }
}

/// Lightweight rollup metrics for session summaries.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMetrics {
    #[serde(default)]
    pub agent_count: u32,
    #[serde(default)]
    pub active_agent_count: u32,
    #[serde(default)]
    pub idle_agent_count: u32,
    #[serde(default)]
    pub awaiting_review_agent_count: u32,
    #[serde(default)]
    pub open_task_count: u32,
    #[serde(default)]
    pub in_progress_task_count: u32,
    #[serde(default)]
    pub awaiting_review_task_count: u32,
    #[serde(default)]
    pub in_review_task_count: u32,
    #[serde(default)]
    pub arbitration_task_count: u32,
    #[serde(default)]
    pub blocked_task_count: u32,
    #[serde(default)]
    pub completed_task_count: u32,
}

impl SessionMetrics {
    #[must_use]
    pub fn recalculate(state: &SessionState) -> Self {
        let agent_count = saturating_len(
            state
                .agents
                .values()
                .filter(|agent| agent.status.is_alive())
                .count(),
        );
        let active_agent_count = saturating_len(
            state
                .agents
                .values()
                .filter(|agent| agent.status == AgentStatus::Active)
                .count(),
        );
        let idle_agent_count = saturating_len(
            state
                .agents
                .values()
                .filter(|agent| agent.status == AgentStatus::Idle)
                .count(),
        );
        let awaiting_review_agent_count = saturating_len(
            state
                .agents
                .values()
                .filter(|agent| agent.status == AgentStatus::AwaitingReview)
                .count(),
        );

        let mut open_task_count = 0_u32;
        let mut in_progress_task_count = 0_u32;
        let mut awaiting_review_task_count = 0_u32;
        let mut in_review_task_count = 0_u32;
        let mut arbitration_task_count = 0_u32;
        let mut blocked_task_count = 0_u32;
        let mut completed_task_count = 0_u32;
        for task in state.tasks.values() {
            match task.status {
                TaskStatus::Open => open_task_count += 1,
                TaskStatus::InProgress => in_progress_task_count += 1,
                TaskStatus::AwaitingReview => awaiting_review_task_count += 1,
                TaskStatus::InReview => in_review_task_count += 1,
                TaskStatus::Done => completed_task_count += 1,
                TaskStatus::Blocked => blocked_task_count += 1,
            }
            if task.arbitration.is_some()
                || task.blocked_reason.as_deref() == Some(ARBITRATION_BLOCKED_REASON)
            {
                arbitration_task_count += 1;
            }
        }

        Self {
            agent_count,
            active_agent_count,
            idle_agent_count,
            awaiting_review_agent_count,
            open_task_count,
            in_progress_task_count,
            awaiting_review_task_count,
            in_review_task_count,
            arbitration_task_count,
            blocked_task_count,
            completed_task_count,
        }
    }
}

fn saturating_len(len: usize) -> u32 {
    u32::try_from(len).unwrap_or(u32::MAX)
}
