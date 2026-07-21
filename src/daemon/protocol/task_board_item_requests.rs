use serde::{Deserialize, Serialize};

use crate::task_board::{
    AgentMode, ExternalRef, PlanningState, TaskBoardPriority, TaskBoardStatus,
    TaskBoardWorkflowKind,
    types::{TaskBoardItemKind, TaskBoardWorkflowState},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardCreateItemRequest {
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub priority: TaskBoardPriority,
    #[serde(default)]
    pub agent_mode: AgentMode,
    #[serde(default)]
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default)]
    pub kind: TaskBoardItemKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_cost_microusd: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_project_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub external_refs: Vec<ExternalRef>,
    #[serde(default)]
    pub planning: PlanningState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardListItemsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardGetItemRequest {
    pub id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateItemRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskBoardPriority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_kind: Option<TaskBoardWorkflowKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<TaskBoardItemKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_cost_microusd: Option<u64>,
    #[serde(default, flatten)]
    pub clear_estimates: TaskBoardUpdateEstimateClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_project_types: Option<Vec<String>>,
    #[serde(default, flatten)]
    pub clear_identity: TaskBoardUpdateIdentityClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_refs: Option<Vec<ExternalRef>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<PlanningState>,
    #[serde(default, flatten)]
    pub clear_state: TaskBoardUpdateStateClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_item_id: Option<String>,
}

#[expect(
    clippy::struct_excessive_bools,
    reason = "wire contract exposes independent identity-clear switches"
)]
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateIdentityClears {
    #[serde(default)]
    pub clear_project_id: bool,
    #[serde(default)]
    pub clear_execution_repository: bool,
    #[serde(default)]
    pub clear_session_id: bool,
    #[serde(default)]
    pub clear_work_item_id: bool,
    #[serde(default)]
    pub clear_parent_item_id: bool,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateEstimateClears {
    #[serde(default)]
    pub clear_estimated_tokens: bool,
    #[serde(default)]
    pub clear_estimated_cost_microusd: bool,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateStateClears {
    #[serde(default)]
    pub clear_planning: bool,
    #[serde(default)]
    pub clear_workflow: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDeleteItemRequest {
    pub id: String,
}
