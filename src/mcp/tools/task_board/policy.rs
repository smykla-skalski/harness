use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
    TaskBoardPolicyExportRequest, TaskBoardPolicyImportRequest,
    TaskBoardPolicyPipelineAuditRequest, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelineGoLiveDiffRequest, TaskBoardPolicyPipelineMakeLiveRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineReplayRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyScenarioCreateRequest, TaskBoardPolicyScenarioDeleteRequest,
    TaskBoardPolicyScenarioUpdateRequest, ws_methods,
};
use crate::mcp::tool::ToolRegistry;

use super::support::{
    TaskBoardToolDescriptor, register_descriptors, validate_empty_object, validate_params,
};

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(registry, &canvas_descriptors());
    register_descriptors(registry, &pipeline_descriptors());
    register_descriptors(registry, &scenario_descriptors());
}

fn canvas_descriptors() -> [TaskBoardToolDescriptor; 7] {
    [
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
            name: ws_methods::TASK_BOARD_POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT,
            description: "Set global policy enforcement.",
            input_schema: global_enforcement_schema,
            normalize: validate_params::<TaskBoardPolicyCanvasSetGlobalEnforcementRequest>,
        },
    ]
}

fn pipeline_descriptors() -> [TaskBoardToolDescriptor; 10] {
    [
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
            description: "Read the task-board policy pipeline document.",
            input_schema: canvas_selector_schema,
            normalize: validate_params::<TaskBoardPolicyPipelineGetRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
            description: "Save a draft task-board policy pipeline document.",
            input_schema: save_draft_schema,
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
            input_schema: canvas_selector_schema,
            normalize: validate_params::<TaskBoardPolicyPipelineAuditRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_EXPORT,
            description: "Export the active policy canvas document as a JSON snapshot.",
            input_schema: canvas_selector_schema,
            normalize: validate_params::<TaskBoardPolicyExportRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_IMPORT,
            description: "Import a policy canvas from a JSON document, creating a new canvas.",
            input_schema: import_schema,
            normalize: validate_params::<TaskBoardPolicyImportRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_PIPELINE_MAKE_LIVE,
            description: "Make a policy pipeline revision live: promote and enable enforcement.",
            input_schema: promote_schema,
            normalize: validate_params::<TaskBoardPolicyPipelineMakeLiveRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_PIPELINE_GO_LIVE_DIFF,
            description: "Diff a candidate policy draft against the live enforced policy.",
            input_schema: document_schema,
            normalize: validate_params::<TaskBoardPolicyPipelineGoLiveDiffRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_PIPELINE_REPLAY,
            description: "Replay the draft policy against the recorded real-decision feed.",
            input_schema: replay_schema,
            normalize: validate_params::<TaskBoardPolicyPipelineReplayRequest>,
        },
    ]
}

fn scenario_descriptors() -> [TaskBoardToolDescriptor; 4] {
    [
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_SCENARIO_CREATE,
            description: "Create an editable policy simulation scenario.",
            input_schema: scenario_create_schema,
            normalize: validate_params::<TaskBoardPolicyScenarioCreateRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_SCENARIO_UPDATE,
            description: "Update an editable policy simulation scenario.",
            input_schema: scenario_update_schema,
            normalize: validate_params::<TaskBoardPolicyScenarioUpdateRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_SCENARIO_DELETE,
            description: "Delete a policy simulation scenario.",
            input_schema: scenario_id_schema,
            normalize: validate_params::<TaskBoardPolicyScenarioDeleteRequest>,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::TASK_BOARD_POLICY_SCENARIO_RESET,
            description: "Reset policy simulation scenarios to the seeded defaults.",
            input_schema: empty_schema,
            normalize: validate_empty_object,
        },
    ]
}

fn empty_schema() -> Value {
    json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    })
}

fn save_draft_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" },
            "if_revision": { "type": "integer", "minimum": 0 },
            "document": {
                "type": "object",
                "additionalProperties": true
            }
        },
        "required": ["document"],
        "additionalProperties": false
    })
}

fn document_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" },
            "document": {
                "type": "object",
                "additionalProperties": true
            }
        },
        "additionalProperties": false
    })
}

fn canvas_selector_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn import_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "document": {
                "type": "object",
                "additionalProperties": true
            },
            "title": { "type": "string" }
        },
        "required": ["document"],
        "additionalProperties": false
    })
}

fn promote_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" },
            "revision": { "type": "integer", "minimum": 0 },
            "actor": { "type": "string" }
        },
        "required": ["revision"],
        "additionalProperties": false
    })
}

fn replay_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "canvas_id": { "type": "string" },
            "limit": { "type": "integer", "minimum": 1 }
        },
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

fn global_enforcement_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "enabled": { "type": "boolean" }
        },
        "required": ["enabled"],
        "additionalProperties": false
    })
}

fn scenario_create_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "name": { "type": "string" },
            "input": { "type": "object", "additionalProperties": true }
        },
        "required": ["name", "input"],
        "additionalProperties": false
    })
}

fn scenario_update_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "name": { "type": "string" },
            "input": { "type": "object", "additionalProperties": true }
        },
        "required": ["id", "name", "input"],
        "additionalProperties": false
    })
}

fn scenario_id_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" }
        },
        "required": ["id"],
        "additionalProperties": false
    })
}
