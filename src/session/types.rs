use std::collections::BTreeMap;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};

/// Current schema version for session state files.
pub const CURRENT_VERSION: u32 = 1;

/// Main versioned state document for a multi-agent orchestration session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub schema_version: u32,
    /// Monotonically increasing counter for optimistic concurrency.
    #[serde(default)]
    pub state_version: u64,
    pub session_id: String,
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
}

/// Session lifecycle status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Active,
    Paused,
    Ended,
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
    Disconnected,
    Removed,
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
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<TaskNote>,
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

/// A note attached to a work item status transition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskNote {
    pub timestamp: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub text: String,
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
    RoleChanged {
        agent_id: String,
        from: SessionRole,
        to: SessionRole,
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
    TaskAssigned {
        task_id: String,
        agent_id: String,
    },
    TaskStatusChanged {
        task_id: String,
        from: TaskStatus,
        to: TaskStatus,
    },
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
            context: "test goal".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T12:00:00Z".into(),
            updated_at: "2026-03-28T12:00:00Z".into(),
            agents: BTreeMap::new(),
            tasks: BTreeMap::new(),
            leader_id: Some("agent-1".into()),
        };
        let json = serde_json::to_string(&state).expect("serializes");
        let parsed: SessionState = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(parsed.session_id, "sess-test");
        assert_eq!(parsed.status, SessionStatus::Active);
        assert_eq!(parsed.leader_id, Some("agent-1".into()));
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
            created_at: "2026-03-28T12:00:00Z".into(),
            updated_at: "2026-03-28T12:00:00Z".into(),
            created_by: Some("agent-1".into()),
            notes: vec![],
        };
        let json = serde_json::to_string(&item).expect("serializes");
        let parsed: WorkItem = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(parsed.task_id, "task-1");
        assert_eq!(parsed.severity, TaskSeverity::High);
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
        use clap::ValueEnum;
        let variants = SessionRole::value_variants();
        assert_eq!(variants.len(), 5);
    }
}
