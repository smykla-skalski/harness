use serde::Deserialize;
use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest, TaskBoardUpdateItemRequest,
    ws_methods,
};
use crate::mcp::tool::ToolRegistry;

use super::support::{TaskBoardToolDescriptor, register_descriptors, validate_params};

/// Deserialization-only shape that pairs the required `id` with the rest of
/// the update payload. Only used to validate caller input before forwarding
/// the raw JSON to the daemon, so the fields are intentionally unread.
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct TaskBoardUpdateToolRequest {
    id: String,
    #[serde(flatten)]
    update: TaskBoardUpdateItemRequest,
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
                normalize: validate_params::<TaskBoardUpdateToolRequest>,
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
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_REVOKE,
                description: "Revoke an approved task-board plan and return it to draft.",
                input_schema: plan_revoke_schema,
                normalize: validate_params::<TaskBoardPlanRevokeRequest>,
            },
        ],
    );
}

fn plan_revoke_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "actor": { "type": "string" }
        },
        "required": ["id"],
        "additionalProperties": false
    })
}

fn create_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "title": { "type": "string" },
            "body": { "type": "string" },
            "priority": { "type": "string" },
            "agent_mode": { "type": "string" },
            "tags": string_array_schema(),
            "project_id": { "type": "string" },
            "target_project_types": string_array_schema(),
            "external_refs": external_refs_schema(),
            "planning": planning_schema(),
            "workflow": { "type": "object" },
            "session_id": { "type": "string" },
            "work_item_id": { "type": "string" },
            "id": { "type": "string" }
        },
        "required": ["title"],
        "additionalProperties": false
    })
}

fn string_array_schema() -> Value {
    json!({
        "type": "array",
        "items": { "type": "string" }
    })
}

fn external_refs_schema() -> Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "properties": {
                "provider": { "type": "string" },
                "external_id": { "type": "string" },
                "url": { "type": "string" }
            },
            "required": ["provider", "external_id"]
        }
    })
}

fn planning_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "summary": { "type": "string" },
            "approved_by": { "type": "string" },
            "approved_at": { "type": "string" }
        }
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
            "id": { "type": "string" },
            "title": { "type": "string" },
            "body": { "type": "string" },
            "status": { "type": "string" },
            "priority": { "type": "string" },
            "agent_mode": { "type": "string" },
            "tags": string_array_schema(),
            "project_id": { "type": "string" },
            "target_project_types": string_array_schema(),
            "clear_project_id": { "type": "boolean" },
            "clear_session_id": { "type": "boolean" },
            "clear_work_item_id": { "type": "boolean" },
            "external_refs": external_refs_schema(),
            "planning": planning_schema(),
            "clear_planning": { "type": "boolean" },
            "clear_workflow": { "type": "boolean" },
            "workflow": { "type": "object" },
            "session_id": { "type": "string" },
            "work_item_id": { "type": "string" }
        },
        "required": ["id"],
        "additionalProperties": false
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
