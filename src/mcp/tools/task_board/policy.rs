use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSimulateRequest, ws_methods,
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
