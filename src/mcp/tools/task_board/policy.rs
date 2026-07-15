use serde_json::{Value, json};

use crate::daemon::protocol::ws_methods;
use crate::mcp::tool::ToolRegistry;

use super::support::{TaskBoardToolDescriptor, register_descriptors};

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(registry, &canvas_descriptors());
    register_descriptors(registry, &spawn_gate_descriptors());
    register_descriptors(registry, &pipeline_descriptors());
    register_descriptors(registry, &scenario_descriptors());
}

fn spawn_gate_descriptors() -> [TaskBoardToolDescriptor; 5] {
    [
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_SET_SPAWN_REQUIRES_LIVE_POLICY,
            description: "Toggle the fail-closed spawn-requires-live-policy switch.",
            input_schema: global_enforcement_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_SET_SPAWN_KILL_SWITCH,
            description: "Toggle the emergency spawn kill switch.",
            input_schema: global_enforcement_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_APPROVAL_GRANTS_LIST,
            description: "List pending approval grants awaiting a decision.",
            input_schema: empty_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_APPROVAL_GRANT_RESOLVE,
            description: "Approve or deny a pending approval grant.",
            input_schema: grant_resolve_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_APPROVAL_GRANT_REVOKE,
            description: "Revoke a live policy approval grant.",
            input_schema: grant_revoke_schema,
        },
    ]
}

fn canvas_descriptors() -> [TaskBoardToolDescriptor; 7] {
    [
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_WORKSPACE_GET,
            description: "Read the policy canvas workspace.",
            input_schema: empty_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_CREATE,
            description: "Create a new policy canvas.",
            input_schema: canvas_create_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_DUPLICATE,
            description: "Duplicate an existing policy canvas.",
            input_schema: canvas_duplicate_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_RENAME,
            description: "Rename a policy canvas.",
            input_schema: canvas_rename_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_SET_ACTIVE,
            description: "Set the active policy canvas.",
            input_schema: canvas_id_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_DELETE,
            description: "Delete a policy canvas.",
            input_schema: canvas_id_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT,
            description: "Set global policy enforcement.",
            input_schema: global_enforcement_schema,
        },
    ]
}

fn pipeline_descriptors() -> [TaskBoardToolDescriptor; 10] {
    [
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_GET,
            description: "Read the policy pipeline document.",
            input_schema: canvas_selector_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
            description: "Save a draft policy pipeline document.",
            input_schema: save_draft_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_SIMULATE,
            description: "Simulate a policy pipeline document.",
            input_schema: document_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_PROMOTE,
            description: "Legacy alias for making a policy pipeline revision live.",
            input_schema: promote_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_AUDIT,
            description: "Read policy pipeline audit summaries.",
            input_schema: canvas_selector_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_EXPORT,
            description: "Export the active policy canvas document as a JSON snapshot.",
            input_schema: canvas_selector_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_CANVAS_IMPORT,
            description: "Import a policy canvas from a JSON document, creating a new canvas.",
            input_schema: import_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_MAKE_LIVE,
            description: "Make a policy pipeline revision live: promote and enable enforcement.",
            input_schema: promote_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
            description: "Diff a candidate policy draft against the live enforced policy.",
            input_schema: document_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_PIPELINE_REPLAY,
            description: "Replay the draft policy against the recorded real-decision feed.",
            input_schema: replay_schema,
        },
    ]
}

fn scenario_descriptors() -> [TaskBoardToolDescriptor; 4] {
    [
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_SCENARIO_CREATE,
            description: "Create an editable policy simulation scenario.",
            input_schema: scenario_create_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_SCENARIO_UPDATE,
            description: "Update an editable policy simulation scenario.",
            input_schema: scenario_update_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_SCENARIO_DELETE,
            description: "Delete a policy simulation scenario.",
            input_schema: scenario_id_schema,
        },
        TaskBoardToolDescriptor {
            name: ws_methods::POLICY_SCENARIO_RESET,
            description: "Reset policy simulation scenarios to the seeded defaults.",
            input_schema: empty_schema,
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

fn grant_resolve_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "grant_id": { "type": "string" },
            "approve": { "type": "boolean" },
            "actor": { "type": "string" }
        },
        "required": ["grant_id", "approve"],
        "additionalProperties": false
    })
}

fn grant_revoke_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "grant_id": { "type": "string" },
            "actor": { "type": "string" }
        },
        "required": ["grant_id"],
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
