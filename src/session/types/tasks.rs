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
    pub observe_issue_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint_summary: Option<TaskCheckpointSummary>,
    /// Metadata for the awaiting-review queue entry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub awaiting_review: Option<AwaitingReview>,
    /// Active reviewer claim, including distinct-runtime reviewer entries.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_claim: Option<ReviewClaim>,
    /// Closed quorum consensus, set once `required_consensus` reviewers agree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consensus: Option<ReviewConsensus>,
    /// Per-round consensus history: each entry is the merged-and-responded
    /// consensus from one completed round, pushed here before
    /// `task.consensus` is cleared so per-point agree/dispute state and
    /// worker notes survive across rounds.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub review_history: Vec<ReviewConsensus>,
    /// Review round counter; increments each time a reworked task goes back to review.
    #[serde(default, skip_serializing_if = "is_default_value")]
    pub review_round: u8,
    /// Leader arbitration outcome once recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arbitration: Option<ArbitrationOutcome>,
    /// Persona hint to bias routing when assigning to a worker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_persona: Option<String>,
}

fn is_default_value<T>(value: &T) -> bool
where
    T: Default + PartialEq,
{
    value == &T::default()
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
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Open,
    #[value(name = "in_progress", alias = "in-progress")]
    InProgress,
    #[value(name = "awaiting_review")]
    AwaitingReview,
    #[value(name = "in_review", alias = "in-review")]
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
    Improver,
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

/// Metadata attached when a worker submits a task for review and the task
/// returns to the queue awaiting a reviewer claim.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AwaitingReview {
    /// ISO-8601 timestamp when the task entered the awaiting-review state.
    pub queued_at: String,
    /// Agent id of the worker that submitted for review.
    pub submitter_agent_id: String,
    /// Optional summary text the worker attached on submission.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Number of distinct-runtime reviewers required to close consensus.
    #[serde(default = "default_required_consensus")]
    pub required_consensus: u8,
}

const fn default_required_consensus() -> u8 {
    2
}

/// One entry in a task's reviewer claim.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewerEntry {
    pub reviewer_agent_id: String,
    pub reviewer_runtime: String,
    pub claimed_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub submitted_at: Option<String>,
}

/// Set of reviewers currently holding or having completed a claim on the task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewClaim {
    #[serde(default)]
    pub reviewers: Vec<ReviewerEntry>,
}

/// A single review record persisted in `tasks/<id>/reviews.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Review {
    pub review_id: String,
    pub round: u8,
    pub reviewer_agent_id: String,
    pub reviewer_runtime: String,
    pub verdict: ReviewVerdict,
    pub summary: String,
    #[serde(default)]
    pub points: Vec<ReviewPoint>,
    pub recorded_at: String,
}

/// Verdict a reviewer chooses on submission.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ReviewVerdict {
    Approve,
    #[value(name = "request_changes", alias = "request-changes")]
    #[serde(alias = "request-changes")]
    RequestChanges,
    Reject,
}

/// Per-point review feedback state.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewPointState {
    #[default]
    Open,
    Agreed,
    Disputed,
    Resolved,
}

/// A single numbered review point the worker may agree to or dispute.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewPoint {
    pub point_id: String,
    pub text: String,
    #[serde(default)]
    pub state: ReviewPointState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_note: Option<String>,
}

/// Aggregated quorum consensus once `required_consensus` distinct-runtime
/// reviewers have submitted compatible verdicts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewConsensus {
    pub verdict: ReviewVerdict,
    pub summary: String,
    #[serde(default)]
    pub points: Vec<ReviewPoint>,
    pub closed_at: String,
    #[serde(default)]
    pub reviewer_agent_ids: Vec<String>,
}

/// `blocked_reason` string written on tasks that exhausted the three-round
/// review cycle and await leader arbitration. Stored with an underscore so
/// filters and metrics can match on one stable slug.
pub const ARBITRATION_BLOCKED_REASON: &str = "awaiting_arbitration";

/// Leader arbitration result for a task that exhausted the three-round
/// review cycle with outstanding disputed points.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArbitrationOutcome {
    pub arbiter_agent_id: String,
    pub verdict: ReviewVerdict,
    pub summary: String,
    pub recorded_at: String,
}
