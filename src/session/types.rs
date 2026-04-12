use std::collections::BTreeMap;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::signal::{AckResult, Signal, SignalAck};

/// Current schema version for session state files.
pub const CURRENT_VERSION: u32 = 6;

/// Main versioned state document for a multi-agent orchestration session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub schema_version: u32,
    /// Monotonically increasing counter for optimistic concurrency.
    #[serde(default)]
    pub state_version: u64,
    pub session_id: String,
    /// Short human-readable session name.
    #[serde(default)]
    pub title: String,
    /// Human-readable session goal.
    pub context: String,
    pub status: SessionStatus,
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
    /// Cached counts for fast daemon and UI list rendering.
    #[serde(default)]
    pub metrics: SessionMetrics,
}

/// Session lifecycle status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Active,
    Paused,
    Ended,
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
    pub open_task_count: u32,
    #[serde(default)]
    pub in_progress_task_count: u32,
    #[serde(default)]
    pub blocked_task_count: u32,
    #[serde(default)]
    pub completed_task_count: u32,
}

impl SessionMetrics {
    #[must_use]
    pub fn recalculate(state: &SessionState) -> Self {
        let agent_count = saturating_len(state.agents.len());
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

        let mut open_task_count = 0_u32;
        let mut in_progress_task_count = 0_u32;
        let mut blocked_task_count = 0_u32;
        let mut completed_task_count = 0_u32;
        for task in state.tasks.values() {
            match task.status {
                TaskStatus::Open => open_task_count += 1,
                TaskStatus::InProgress | TaskStatus::InReview => in_progress_task_count += 1,
                TaskStatus::Done => completed_task_count += 1,
                TaskStatus::Blocked => blocked_task_count += 1,
            }
        }

        Self {
            agent_count,
            active_agent_count,
            idle_agent_count,
            open_task_count,
            in_progress_task_count,
            blocked_task_count,
            completed_task_count,
        }
    }
}

/// An agent registered in a multi-agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRegistration {
    pub agent_id: String,
    /// Human-readable display name.
    pub name: String,
    /// Agent runtime identifier (stored as string for forward compatibility).
    pub runtime: String,
    pub role: SessionRole,
    /// Free-form capability tags declared on join.
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub joined_at: String,
    pub updated_at: String,
    pub status: AgentStatus,
    /// Link to the agent's individual session in the agents ledger.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_id: Option<String>,
    /// Most recent observed activity for this agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
    /// Current assigned work item, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_task_id: Option<String>,
    /// Runtime delivery and transcript features for UI badges.
    #[serde(default)]
    pub runtime_capabilities: RuntimeCapabilities,
}

/// A pending leadership transfer initiated by a non-leader actor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingLeaderTransfer {
    pub requested_by: String,
    pub current_leader_id: String,
    pub new_leader_id: String,
    pub requested_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Role an agent holds within a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum SessionRole {
    Leader,
    Observer,
    Worker,
    Reviewer,
    Improver,
}

/// Whether an agent is actively participating.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Active,
    /// Agent is alive but has not used tools recently.
    Idle,
    Disconnected,
    Removed,
}

impl AgentStatus {
    /// Whether the agent is considered alive (able to perform actions).
    #[must_use]
    pub const fn is_alive(self) -> bool {
        matches!(self, Self::Active | Self::Idle)
    }
}

/// A work item tracked within a session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkItem {
    pub task_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    pub severity: TaskSeverity,
    pub status: TaskStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assigned_to: Option<String>,
    #[serde(default, skip_serializing_if = "TaskQueuePolicy::is_default")]
    pub queue_policy: TaskQueuePolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queued_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<TaskNote>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_fix: Option<String>,
    #[serde(default)]
    pub source: TaskSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint_summary: Option<TaskCheckpointSummary>,
}

/// Severity level for a work item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum TaskSeverity {
    Low,
    Medium,
    High,
    Critical,
}

/// Status of a work item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Open,
    InProgress,
    InReview,
    Done,
    Blocked,
}

/// Whether a queued task can move to another free worker before its selected
/// worker becomes available.
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[serde(rename_all = "snake_case")]
pub enum TaskQueuePolicy {
    #[default]
    Locked,
    ReassignWhenFree,
}

impl TaskQueuePolicy {
    #[must_use]
    pub const fn is_default(&self) -> bool {
        matches!(self, Self::Locked)
    }
}

/// Source that introduced a work item.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskSource {
    #[default]
    Manual,
    Observe,
    Signal,
    System,
}

/// A note attached to a work item status transition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskNote {
    pub timestamp: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub text: String,
}

/// A single append-only task checkpoint record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCheckpoint {
    pub checkpoint_id: String,
    pub task_id: String,
    pub recorded_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor_id: Option<String>,
    pub summary: String,
    pub progress: u8,
}

/// Snapshot of the latest checkpoint for a task.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCheckpointSummary {
    pub checkpoint_id: String,
    pub recorded_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor_id: Option<String>,
    pub summary: String,
    pub progress: u8,
}

impl From<&TaskCheckpoint> for TaskCheckpointSummary {
    fn from(value: &TaskCheckpoint) -> Self {
        Self {
            checkpoint_id: value.checkpoint_id.clone(),
            recorded_at: value.recorded_at.clone(),
            actor_id: value.actor_id.clone(),
            summary: value.summary.clone(),
            progress: value.progress,
        }
    }
}

/// Session-visible signal status for CLI and daemon rendering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionSignalStatus {
    Pending,
    Acknowledged,
    Rejected,
    Deferred,
    Expired,
}

impl SessionSignalStatus {
    #[must_use]
    pub fn from_ack_result(result: AckResult) -> Self {
        match result {
            AckResult::Accepted => Self::Acknowledged,
            AckResult::Rejected => Self::Rejected,
            AckResult::Deferred => Self::Deferred,
            AckResult::Expired => Self::Expired,
        }
    }
}

/// A signal visible within a multi-agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSignalRecord {
    pub runtime: String,
    pub agent_id: String,
    pub session_id: String,
    pub status: SessionSignalStatus,
    pub signal: Signal,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acknowledgment: Option<SignalAck>,
}

/// An append-only log entry recording a session state transition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionLogEntry {
    pub sequence: u64,
    pub recorded_at: String,
    pub session_id: String,
    pub transition: SessionTransition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Discriminated session state transitions for the audit log.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionTransition {
    SessionStarted {
        #[serde(default)]
        title: String,
        context: String,
    },
    SessionEnded,
    AgentJoined {
        agent_id: String,
        role: SessionRole,
        runtime: String,
    },
    AgentRemoved {
        agent_id: String,
    },
    AgentDisconnected {
        agent_id: String,
        reason: String,
    },
    AgentLeft {
        agent_id: String,
    },
    LivenessSynced {
        disconnected: Vec<String>,
        idled: Vec<String>,
    },
    RoleChanged {
        agent_id: String,
        from: SessionRole,
        to: SessionRole,
    },
    LeaderTransferRequested {
        from: String,
        to: String,
    },
    LeaderTransferConfirmed {
        from: String,
        to: String,
        confirmed_by: String,
    },
    LeaderTransferred {
        from: String,
        to: String,
    },
    TaskCreated {
        task_id: String,
        title: String,
        severity: TaskSeverity,
    },
    ObserveTaskCreated {
        task_id: String,
        title: String,
        severity: TaskSeverity,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        issue_id: Option<String>,
    },
    TaskAssigned {
        task_id: String,
        agent_id: String,
    },
    TaskQueued {
        task_id: String,
        agent_id: String,
    },
    TaskStatusChanged {
        task_id: String,
        from: TaskStatus,
        to: TaskStatus,
    },
    TaskCheckpointRecorded {
        task_id: String,
        checkpoint_id: String,
        progress: u8,
    },
    SignalSent {
        signal_id: String,
        agent_id: String,
        command: String,
    },
    SignalAcknowledged {
        signal_id: String,
        agent_id: String,
        result: AckResult,
    },
}

fn saturating_len(len: usize) -> u32 {
    u32::try_from(len).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_state_serde_round_trip() {
        let state = SessionState {
            schema_version: CURRENT_VERSION,
            state_version: 1,
            session_id: "sess-test".into(),
            title: "test session".into(),
            context: "test goal".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T12:00:00Z".into(),
            updated_at: "2026-03-28T12:00:00Z".into(),
            agents: BTreeMap::new(),
            tasks: BTreeMap::new(),
            leader_id: Some("agent-1".into()),
            archived_at: None,
            last_activity_at: Some("2026-03-28T12:00:00Z".into()),
            observe_id: Some("observe-sess-test".into()),
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        };
        let json = serde_json::to_string(&state).expect("serializes");
        let parsed: SessionState = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(parsed.session_id, "sess-test");
        assert_eq!(parsed.status, SessionStatus::Active);
        assert_eq!(parsed.leader_id, Some("agent-1".into()));
        assert_eq!(parsed.observe_id.as_deref(), Some("observe-sess-test"));
    }

    #[test]
    fn session_state_without_title_deserializes_with_empty_default() {
        let json = r#"{
            "schema_version": 3,
            "session_id": "old-sess",
            "context": "legacy goal",
            "status": "active",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z"
        }"#;
        let state: SessionState = serde_json::from_str(json).expect("deserializes");
        assert_eq!(state.session_id, "old-sess");
        assert_eq!(state.title, "");
        assert_eq!(state.context, "legacy goal");
    }

    #[test]
    fn work_item_serde_round_trip() {
        let item = WorkItem {
            task_id: "task-1".into(),
            title: "fix bug".into(),
            context: Some("details here".into()),
            severity: TaskSeverity::High,
            status: TaskStatus::Open,
            assigned_to: None,
            queue_policy: TaskQueuePolicy::Locked,
            queued_at: None,
            created_at: "2026-03-28T12:00:00Z".into(),
            updated_at: "2026-03-28T12:00:00Z".into(),
            created_by: Some("agent-1".into()),
            notes: vec![],
            suggested_fix: Some("check the failing watch path".into()),
            source: TaskSource::Manual,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
        };
        let json = serde_json::to_string(&item).expect("serializes");
        let parsed: WorkItem = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(parsed.task_id, "task-1");
        assert_eq!(parsed.severity, TaskSeverity::High);
        assert_eq!(
            parsed.suggested_fix.as_deref(),
            Some("check the failing watch path")
        );
    }

    #[test]
    fn session_transition_serde_tagged() {
        let entry = SessionLogEntry {
            sequence: 1,
            recorded_at: "2026-03-28T12:00:00Z".into(),
            session_id: "sess-test".into(),
            transition: SessionTransition::AgentJoined {
                agent_id: "codex-abc".into(),
                role: SessionRole::Worker,
                runtime: "codex".into(),
            },
            actor_id: Some("leader-1".into()),
            reason: None,
        };
        let json = serde_json::to_string(&entry).expect("serializes");
        assert!(json.contains("\"kind\":\"agent_joined\""));
        let parsed: SessionLogEntry = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(parsed.sequence, 1);
    }

    #[test]
    fn session_role_clap_value_enum() {
        let variants = SessionRole::value_variants();
        assert_eq!(variants.len(), 5);
    }

    #[test]
    fn session_metrics_recalculate_counts_agents_and_tasks() {
        let mut tasks = BTreeMap::new();
        tasks.insert(
            "task-1".into(),
            WorkItem {
                task_id: "task-1".into(),
                title: "one".into(),
                context: None,
                severity: TaskSeverity::Medium,
                status: TaskStatus::Open,
                assigned_to: None,
                queue_policy: TaskQueuePolicy::Locked,
                queued_at: None,
                created_at: "2026-03-28T12:00:00Z".into(),
                updated_at: "2026-03-28T12:00:00Z".into(),
                created_by: None,
                notes: vec![],
                suggested_fix: None,
                source: TaskSource::Manual,
                blocked_reason: None,
                completed_at: None,
                checkpoint_summary: None,
            },
        );
        tasks.insert(
            "task-2".into(),
            WorkItem {
                task_id: "task-2".into(),
                title: "two".into(),
                context: None,
                severity: TaskSeverity::Medium,
                status: TaskStatus::Done,
                assigned_to: None,
                queue_policy: TaskQueuePolicy::Locked,
                queued_at: None,
                created_at: "2026-03-28T12:00:00Z".into(),
                updated_at: "2026-03-28T12:00:00Z".into(),
                created_by: None,
                notes: vec![],
                suggested_fix: None,
                source: TaskSource::Manual,
                blocked_reason: None,
                completed_at: Some("2026-03-28T12:03:00Z".into()),
                checkpoint_summary: None,
            },
        );

        let mut agents = BTreeMap::new();
        agents.insert(
            "a1".into(),
            AgentRegistration {
                agent_id: "a1".into(),
                name: "agent".into(),
                runtime: "codex".into(),
                role: SessionRole::Leader,
                capabilities: vec![],
                joined_at: "2026-03-28T12:00:00Z".into(),
                updated_at: "2026-03-28T12:00:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: None,
                last_activity_at: None,
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );

        let state = SessionState {
            schema_version: CURRENT_VERSION,
            state_version: 1,
            session_id: "sess-1".into(),
            title: "test title".into(),
            context: "ctx".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T12:00:00Z".into(),
            updated_at: "2026-03-28T12:00:00Z".into(),
            agents,
            tasks,
            leader_id: Some("a1".into()),
            archived_at: None,
            last_activity_at: None,
            observe_id: None,
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        };

        let metrics = SessionMetrics::recalculate(&state);
        assert_eq!(metrics.agent_count, 1);
        assert_eq!(metrics.active_agent_count, 1);
        assert_eq!(metrics.open_task_count, 1);
        assert_eq!(metrics.completed_task_count, 1);
    }

    #[test]
    fn idle_agent_status_serde_round_trip() {
        let json = r#""idle""#;
        let status: AgentStatus = serde_json::from_str(json).expect("deserializes idle");
        assert_eq!(status, AgentStatus::Idle);
        let serialized = serde_json::to_string(&status).expect("serializes");
        assert_eq!(serialized, r#""idle""#);
    }

    #[test]
    fn metrics_exclude_idle_from_active_count() {
        let mut agents = BTreeMap::new();
        agents.insert(
            "a1".into(),
            AgentRegistration {
                agent_id: "a1".into(),
                name: "leader".into(),
                runtime: "claude".into(),
                role: SessionRole::Leader,
                capabilities: vec![],
                joined_at: "2026-03-28T12:00:00Z".into(),
                updated_at: "2026-03-28T12:00:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: None,
                last_activity_at: None,
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );
        agents.insert(
            "a2".into(),
            AgentRegistration {
                agent_id: "a2".into(),
                name: "idle-worker".into(),
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec![],
                joined_at: "2026-03-28T12:00:00Z".into(),
                updated_at: "2026-03-28T12:00:00Z".into(),
                status: AgentStatus::Idle,
                agent_session_id: None,
                last_activity_at: None,
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );
        agents.insert(
            "a3".into(),
            AgentRegistration {
                agent_id: "a3".into(),
                name: "dead-worker".into(),
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec![],
                joined_at: "2026-03-28T12:00:00Z".into(),
                updated_at: "2026-03-28T12:00:00Z".into(),
                status: AgentStatus::Disconnected,
                agent_session_id: None,
                last_activity_at: None,
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );

        let state = SessionState {
            schema_version: CURRENT_VERSION,
            state_version: 1,
            session_id: "sess-1".into(),
            title: "test".into(),
            context: "ctx".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T12:00:00Z".into(),
            updated_at: "2026-03-28T12:00:00Z".into(),
            agents,
            tasks: BTreeMap::new(),
            leader_id: Some("a1".into()),
            archived_at: None,
            last_activity_at: None,
            observe_id: None,
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        };

        let metrics = SessionMetrics::recalculate(&state);
        assert_eq!(metrics.agent_count, 3);
        assert_eq!(
            metrics.active_agent_count, 1,
            "only Active counts, not Idle"
        );
        assert_eq!(metrics.idle_agent_count, 1);
    }
}
