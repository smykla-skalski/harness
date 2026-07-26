use serde::{Deserialize, Serialize};

use crate::task_board::{DispatchAppliedTask, DispatchPlan, TaskBoardItem};

use crate::session::wire::{ManagedAgentSnapshot, ManagedAgentSnapshotSchema};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardDispatchDeliverRequest {
    pub item_id: String,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardDispatchDeliverResponse {
    pub intent_id: String,
    pub applied: DispatchAppliedTask,
    pub rendered_prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(value_type = Option<ManagedAgentSnapshotSchema>)]
    pub started_agent: Option<ManagedAgentSnapshot>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardDispatchPickRequest {}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardDispatchPickResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<TaskBoardDispatchPickSelection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardDispatchPickSelection {
    pub item: TaskBoardItem,
    pub plan: DispatchPlan,
}
