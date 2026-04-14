use clap::ValueEnum;
use serde::{Deserialize, Serialize};

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
