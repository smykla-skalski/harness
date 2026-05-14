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
    #[serde(default)]
    pub agent_mode: AgentMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub external_refs: Vec<ExternalRef>,
    #[serde(default)]
    pub planning: PlanningState,
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
            agent_mode: AgentMode::Headless,
            external_refs: Vec::new(),
            planning: PlanningState::default(),
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalRefProvider {
    GitHub,
    Todoist,
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
