use serde::{Deserialize, Serialize};

use crate::task_board::{DispatchAppliedTask, DispatchPlan, TaskBoardItem};

use super::ManagedAgentSnapshot;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDispatchDeliverRequest {
    pub item_id: String,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDispatchDeliverResponse {
    pub intent_id: String,
    pub applied: DispatchAppliedTask,
    pub rendered_prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_agent: Option<ManagedAgentSnapshot>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardDispatchPickRequest {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDispatchPickResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<TaskBoardDispatchPickSelection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDispatchPickSelection {
    pub item: TaskBoardItem,
    pub plan: DispatchPlan,
}
