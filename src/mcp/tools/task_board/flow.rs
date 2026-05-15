use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardDispatchRequest,
    TaskBoardEvaluateRequest, TaskBoardSyncRequest, ws_methods,
};
use crate::mcp::tool::ToolRegistry;

use super::support::{TaskBoardToolDescriptor, register_descriptors, validate_params};

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(
        registry,
        &[
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_SYNC,
                description: "Synchronize task-board items with external systems.",
                input_schema: sync_schema,
                normalize: validate_params::<TaskBoardSyncRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_DISPATCH,
                description: "Dispatch task-board work through the daemon.",
                input_schema: dispatch_schema,
                normalize: validate_params::<TaskBoardDispatchRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_EVALUATE,
                description: "Evaluate task-board work through the daemon.",
                input_schema: dispatch_schema,
                normalize: validate_params::<TaskBoardEvaluateRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_AUDIT,
                description: "Read task-board audit summaries from the daemon.",
                input_schema: status_filter_schema,
                normalize: validate_params::<TaskBoardAuditRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PROJECTS,
                description: "List task-board project summaries from the daemon.",
                input_schema: status_filter_schema,
                normalize: validate_params::<TaskBoardCatalogRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_MACHINES,
                description: "List task-board machine summaries from the daemon.",
                input_schema: status_filter_schema,
                normalize: validate_params::<TaskBoardCatalogRequest>,
            },
        ],
    );
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

fn sync_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "status": { "type": "string" },
            "provider": { "type": "string" },
            "direction": { "type": "string" },
            "conflict_policy": { "type": "string" },
            "dry_run": { "type": "boolean" }
        },
        "additionalProperties": false
    })
}

fn dispatch_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "item_id": { "type": "string" },
            "status": { "type": "string" },
            "dry_run": { "type": "boolean" },
            "project_dir": { "type": "string" },
            "actor": { "type": "string" }
        },
        "additionalProperties": false
    })
}
