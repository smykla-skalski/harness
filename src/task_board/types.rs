use clap::ValueEnum;
use serde::{Deserialize, Serialize};

pub const CURRENT_TASK_BOARD_ITEM_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardItem {
    pub schema_version: u32,
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub status: TaskBoardStatus,
    #[serde(default)]
    pub priority: TaskBoardPriority,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_project_types: Vec<String>,
    #[serde(default)]
    pub agent_mode: AgentMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub external_refs: Vec<ExternalRef>,
    #[serde(default)]
    pub planning: PlanningState,
    #[serde(default, skip_serializing_if = "TaskBoardWorkflowState::is_default")]
    pub workflow: TaskBoardWorkflowState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default)]
    pub usage: TaskUsage,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deleted_at: Option<String>,
}

impl TaskBoardItem {
    #[must_use]
    pub fn new(id: String, title: String, body: String, now: String) -> Self {
        Self {
            schema_version: CURRENT_TASK_BOARD_ITEM_VERSION,
            id,
            title,
            body,
            status: TaskBoardStatus::New,
            priority: TaskBoardPriority::Medium,
            tags: Vec::new(),
            project_id: None,
            target_project_types: Vec::new(),
            agent_mode: AgentMode::Headless,
            external_refs: Vec::new(),
            planning: PlanningState::default(),
            workflow: TaskBoardWorkflowState::default(),
            session_id: None,
            work_item_id: None,
            usage: TaskUsage::default(),
            created_at: now.clone(),
            updated_at: now,
            deleted_at: None,
        }
    }

    #[must_use]
    pub const fn is_deleted(&self) -> bool {
        self.deleted_at.is_some()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardWorkflowState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_id: Option<String>,
    #[serde(default)]
    pub status: TaskBoardWorkflowStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_step_id: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub attempts: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_number: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

/// Maximum number of policy trace ids retained per item. Oldest entries are
/// dropped when the cap is reached so an item that re-dispatches indefinitely
/// cannot grow unbounded on disk.
pub const MAX_POLICY_TRACE_IDS: usize = 32;

impl TaskBoardWorkflowState {
    #[must_use]
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    /// Append a policy trace id, capping growth at `MAX_POLICY_TRACE_IDS` by
    /// dropping the oldest ids first.
    pub fn push_policy_trace_id(&mut self, trace_id: String) {
        self.policy_trace_ids.push(trace_id);
        let len = self.policy_trace_ids.len();
        if len > MAX_POLICY_TRACE_IDS {
            self.policy_trace_ids.drain(0..len - MAX_POLICY_TRACE_IDS);
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardWorkflowStatus {
    #[default]
    Idle,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardStatus {
    #[default]
    New,
    Planning,
    #[value(name = "plan_review")]
    PlanReview,
    #[value(name = "needs_you", alias = "needs-you")]
    NeedsYou,
    Todo,
    #[value(name = "in_progress", alias = "in-progress")]
    InProgress,
    #[value(name = "in_review", alias = "in-review")]
    InReview,
    Done,
    Blocked,
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardPriority {
    Low,
    #[default]
    Medium,
    High,
    Critical,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum AgentMode {
    #[default]
    Headless,
    Interactive,
    Planning,
    Evaluate,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalRef {
    pub provider: ExternalRefProvider,
    pub external_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_state: Option<ExternalRefSyncState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalRefProvider {
    GitHub,
    Todoist,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalRefSyncState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub synced_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanningState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TaskUsage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
}

#[allow(clippy::trivially_copy_pass_by_ref)]
fn is_zero(value: &u32) -> bool {
    *value == 0
}

#[cfg(test)]
mod tests {
    use super::{MAX_POLICY_TRACE_IDS, TaskBoardWorkflowState};

    #[test]
    fn dispatch_policy_trace_ids_caps_growth_at_32() {
        let mut workflow = TaskBoardWorkflowState::default();
        for index in 0..40 {
            workflow.push_policy_trace_id(format!("trace-{index:02}"));
        }

        assert_eq!(workflow.policy_trace_ids.len(), MAX_POLICY_TRACE_IDS);
        assert_eq!(
            workflow.policy_trace_ids.first().map(String::as_str),
            Some("trace-08")
        );
        assert_eq!(
            workflow.policy_trace_ids.last().map(String::as_str),
            Some("trace-39")
        );
    }
}
