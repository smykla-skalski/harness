use serde::{Deserialize, Serialize};

use crate::task_board::types::TaskBoardWorkflowState;
use crate::task_board::{
    AgentMode, DispatchExecutionSummary, ExternalRef, PlanningState, TaskBoardAuditSummary,
    TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardSyncSummary,
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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
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
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default)]
    pub clear_project_id: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_refs: Option<Vec<ExternalRef>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<PlanningState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default)]
    pub clear_session_id: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default)]
    pub clear_work_item_id: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDeleteItemRequest {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardListItemsResponse {
    pub items: Vec<TaskBoardItem>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardSyncRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardDispatchRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default)]
    pub dry_run: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardAuditRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

pub type TaskBoardSyncResponse = TaskBoardSyncSummary;
pub type TaskBoardDispatchResponse = DispatchExecutionSummary;
pub type TaskBoardAuditResponse = TaskBoardAuditSummary;
