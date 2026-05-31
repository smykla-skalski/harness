use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyExportRequest,
    TaskBoardPolicyImportRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest, ws_methods,
};
use crate::mcp::tool::ToolRegistry;

use super::support::{
    TaskBoardToolDescriptor, register_descriptors, validate_empty_object, validate_params,
};

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(
        registry,
        &[
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET,
                description: "Read the task-board policy canvas workspace.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_CANVAS_CREATE,
                description: "Create a new task-board policy canvas.",
                input_schema: canvas_create_schema,
                normalize: validate_params::<TaskBoardPolicyCanvasCreateRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_CANVAS_DUPLICATE,
                description: "Duplicate an existing task-board policy canvas.",
                input_schema: canvas_duplicate_schema,
                normalize: validate_params::<TaskBoardPolicyCanvasDuplicateRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_CANVAS_RENAME,
                description: "Rename a task-board policy canvas.",
                input_schema: canvas_rename_schema,
                normalize: validate_params::<TaskBoardPolicyCanvasRenameRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_CANVAS_SET_ACTIVE,
                description: "Set the active task-board policy canvas.",
                input_schema: canvas_id_schema,
                normalize: validate_params::<TaskBoardPolicyCanvasSetActiveRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_CANVAS_DELETE,
                description: "Delete a task-board policy canvas.",
                input_schema: canvas_id_schema,
                normalize: validate_params::<TaskBoardPolicyCanvasDeleteRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
                description: "Read the task-board policy pipeline document.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
                description: "Save a draft task-board policy pipeline document.",
                input_schema: document_schema,
                normalize: validate_params::<TaskBoardPolicyPipelineSaveDraftRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
                description: "Simulate a task-board policy pipeline document.",
                input_schema: document_schema,
                normalize: validate_params::<TaskBoardPolicyPipelineSimulateRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
                description: "Promote a task-board policy pipeline document revision.",
                input_schema: promote_schema,
                normalize: validate_params::<TaskBoardPolicyPipelinePromoteRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
                description: "Read task-board policy pipeline audit summaries.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_EXPORT,
                description: "Export the active policy canvas document as a JSON snapshot.",
                input_schema: empty_schema,
                normalize: validate_params::<TaskBoardPolicyExportRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POLICY_IMPORT,
                description: "Import a policy canvas from a JSON document, creating a new canvas.",
                input_schema: document_schema,
                normalize: validate_params::<TaskBoardPolicyImportRequest>,
            },
        ],
    );
}

fn empty_schema() -> Value {
    json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    })
}

fn document_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "document": {
                "type": "object",
                "additionalProperties": true
            }
        },
        "additionalProperties": false
    })
}

fn promote_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "revision": { "type": "integer", "minimum": 0 }
        },
        "required": ["revision"],
        "additionalProperties": false
    })
}

fn canvas_create_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "title": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn canvas_duplicate_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" },
            "title": { "type": "string" }
        },
        "required": ["canvas_id"],
        "additionalProperties": false
    })
}

fn canvas_rename_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" },
            "title": { "type": "string" }
        },
        "required": ["canvas_id", "title"],
        "additionalProperties": false
    })
}

fn canvas_id_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" }
        },
        "required": ["canvas_id"],
        "additionalProperties": false
    })
}
