use serde::Deserialize;
use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanSubmitRequest, TaskBoardUpdateItemRequest, ws_methods,
};
use crate::mcp::tool::ToolRegistry;

use crate::mcp::tool::ToolError;

use super::support::{TaskBoardToolDescriptor, register_descriptors, validate_params};

#[derive(Debug, Deserialize)]
struct TaskBoardUpdateToolRequest {
    id: String,
    #[serde(flatten)]
    update: TaskBoardUpdateItemRequest,
}

fn validate_update_params(params: Value) -> Result<Value, ToolError> {
    let normalized = validate_params::<TaskBoardUpdateToolRequest>(params)?;
    let TaskBoardUpdateToolRequest { id, update } = serde_json::from_value(normalized.clone())
        .map_err(|error| ToolError::invalid(error.to_string()))?;
    let _ = (id, update);
    Ok(normalized)
}

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(
        registry,
        &[
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_CREATE,
                description: "Create a task-board item through the running daemon.",
                input_schema: create_schema,
                normalize: validate_params::<TaskBoardCreateItemRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_LIST,
                description: "List task-board items from the running daemon.",
                input_schema: status_filter_schema,
                normalize: validate_params::<TaskBoardListItemsRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GET,
                description: "Fetch one task-board item by id.",
                input_schema: id_only_schema,
                normalize: validate_params::<TaskBoardGetItemRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_UPDATE,
                description: "Update a task-board item by id.",
                input_schema: update_schema,
                normalize: validate_update_params,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_DELETE,
                description: "Delete a task-board item by id.",
                input_schema: id_only_schema,
                normalize: validate_params::<TaskBoardDeleteItemRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_BEGIN,
                description: "Begin planning for a task-board item.",
                input_schema: id_only_schema,
                normalize: validate_params::<TaskBoardPlanBeginRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_SUBMIT,
                description: "Submit a task-board plan summary for review.",
                input_schema: plan_submit_schema,
                normalize: validate_params::<TaskBoardPlanSubmitRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_APPROVE,
                description: "Approve a task-board plan.",
                input_schema: plan_approve_schema,
                normalize: validate_params::<TaskBoardPlanApproveRequest>,
            },
        ],
    );
}

fn create_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "title": { "type": "string" },
            "body": { "type": "string" },
            "priority": { "type": "string" },
            "agent_mode": { "type": "string" },
            "project_id": { "type": "string" },
            "session_id": { "type": "string" },
            "work_item_id": { "type": "string" }
        },
        "required": ["title"],
        "additionalProperties": true
    })
}

fn status_filter_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "status": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn id_only_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" }
        },
        "required": ["id"],
        "additionalProperties": false
    })
}

fn update_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" }
        },
        "required": ["id"],
        "additionalProperties": true
    })
}

fn plan_submit_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "summary": { "type": "string" }
        },
        "required": ["id", "summary"],
        "additionalProperties": false
    })
}

fn plan_approve_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "approved_by": { "type": "string" },
            "approved_at": { "type": "string" }
        },
        "required": ["id", "approved_by"],
        "additionalProperties": false
    })
}
