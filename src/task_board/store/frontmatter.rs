use serde::{Deserialize, Serialize};

use super::super::TaskBoardWorkflowKind;
use super::super::lane::TaskBoardLaneOrigin;
use super::super::types::{
    AgentMode, ExternalRef, ExternalRefProvider, PlanningState, TaskBoardItem, TaskBoardItemKind,
    TaskBoardPriority, TaskBoardStatus, TaskBoardWorkflowState, TaskUsage,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct TaskBoardFrontmatter {
    schema_version: u32,
    id: String,
    title: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    target_project_types: Vec<String>,
    agent_mode: AgentMode,
    #[serde(default)]
    workflow_kind: TaskBoardWorkflowKind,
    #[serde(default)]
    kind: TaskBoardItemKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    execution_repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    estimated_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    estimated_cost_microusd: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    external_refs: Vec<ExternalRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    imported_from_provider: Option<ExternalRefProvider>,
    #[serde(default)]
    planning: PlanningState,
    #[serde(default, skip_serializing_if = "TaskBoardWorkflowState::is_default")]
    workflow: TaskBoardWorkflowState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    work_item_id: Option<String>,
    #[serde(default)]
    usage: TaskUsage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    parent_item_id: Option<String>,
    #[serde(default)]
    child_order: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    lane_position: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    lane_origin: Option<TaskBoardLaneOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    lane_set_at: Option<String>,
    created_at: String,
    updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deleted_at: Option<String>,
}

impl From<&TaskBoardItem> for TaskBoardFrontmatter {
    fn from(item: &TaskBoardItem) -> Self {
        Self {
            schema_version: item.schema_version,
            id: item.id.clone(),
            title: item.title.clone(),
            status: item.status,
            priority: item.priority,
            tags: item.tags.clone(),
            project_id: item.project_id.clone(),
            target_project_types: item.target_project_types.clone(),
            agent_mode: item.agent_mode,
            workflow_kind: item.workflow_kind,
            kind: item.kind.clone(),
            execution_repository: item.execution_repository.clone(),
            estimated_tokens: item.estimated_tokens,
            estimated_cost_microusd: item.estimated_cost_microusd,
            external_refs: item.external_refs.clone(),
            imported_from_provider: item.imported_from_provider,
            planning: item.planning.clone(),
            workflow: item.workflow.clone(),
            session_id: item.session_id.clone(),
            work_item_id: item.work_item_id.clone(),
            usage: item.usage.clone(),
            parent_item_id: item.parent_item_id.clone(),
            child_order: item.child_order,
            lane_position: item.lane_position,
            lane_origin: item.lane_origin.clone(),
            lane_set_at: item.lane_set_at.clone(),
            created_at: item.created_at.clone(),
            updated_at: item.updated_at.clone(),
            deleted_at: item.deleted_at.clone(),
        }
    }
}

impl TaskBoardFrontmatter {
    pub(super) fn into_item(self, body: String) -> TaskBoardItem {
        TaskBoardItem {
            schema_version: self.schema_version,
            id: self.id,
            title: self.title,
            body,
            status: self.status,
            priority: self.priority,
            tags: self.tags,
            project_id: self.project_id,
            target_project_types: self.target_project_types,
            agent_mode: self.agent_mode,
            workflow_kind: self.workflow_kind,
            kind: self.kind,
            execution_repository: self.execution_repository,
            estimated_tokens: self.estimated_tokens,
            estimated_cost_microusd: self.estimated_cost_microusd,
            external_refs: self.external_refs,
            imported_from_provider: self.imported_from_provider,
            planning: self.planning,
            workflow: self.workflow,
            session_id: self.session_id,
            work_item_id: self.work_item_id,
            usage: self.usage,
            parent_item_id: self.parent_item_id,
            child_order: self.child_order,
            lane_position: self.lane_position,
            lane_origin: self.lane_origin,
            lane_set_at: self.lane_set_at,
            created_at: self.created_at,
            updated_at: self.updated_at,
            deleted_at: self.deleted_at,
            tombstone_cause: None,
        }
    }
}
