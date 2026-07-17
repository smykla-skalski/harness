use serde_json::{Value, json};

use crate::daemon::protocol::ws_methods;
use crate::mcp::tool::ToolRegistry;

use super::support::{TaskBoardToolDescriptor, register_descriptors};

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(
        registry,
        &[
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
                description: "Read task-board orchestrator status from the daemon.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_START,
                description: "Start the task-board orchestrator.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
                description: "Stop the task-board orchestrator.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
                description: "Run one task-board orchestrator tick.",
                input_schema: dispatch_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
                description: "Read task-board orchestrator settings.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
                description: "Update task-board orchestrator settings.",
                input_schema: settings_update_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
                description: "Read task-board git runtime configuration.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
                description: "Update task-board git runtime configuration.",
                input_schema: permissive_object_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
                description: "Sync task-board GitHub tokens into daemon runtime state.",
                input_schema: github_tokens_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
                description: "Sync the task-board Todoist token into daemon runtime state.",
                input_schema: todoist_token_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC,
                description: "Sync the task-board OpenRouter token into daemon runtime state.",
                input_schema: openrouter_token_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
                description: "Discover system-level git identity defaults (git config, gh CLI, ~/.ssh, env vars).",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY,
                description: "Verify the active git signing profile by producing a probe signature.",
                input_schema: signing_verify_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
                description: "Prepare a non-destructive handoff of legacy task-board git secrets to a secure store.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
                description: "Acknowledge a verified task-board git secret handoff and retire its legacy envelope.",
                input_schema: secret_handoff_ack_schema,
            },
        ],
    );
}

fn signing_verify_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "repository": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn secret_handoff_ack_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "migration_id": { "type": "string" },
            "digest": { "type": "string" }
        },
        "required": ["migration_id", "digest"],
        "additionalProperties": false
    })
}

fn empty_schema() -> Value {
    json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    })
}

fn dispatch_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "item_id": { "type": "string" },
            "dry_run": { "type": "boolean" },
            "status": { "type": "string" },
            "project_dir": { "type": "string" },
            "actor": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn settings_update_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "dry_run_default": { "type": "boolean" },
            "dispatch_status_filter": { "type": "string" },
            "clear_dispatch_status_filter": { "type": "boolean" },
            "project_dir": { "type": "string" },
            "clear_project_dir": { "type": "boolean" },
            "admission_policy": admission_policy_schema(),
            "policy_version": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn admission_policy_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "limits": {
                "type": "array",
                "items": admission_limit_schema()
            },
            "windows": {
                "type": "array",
                "items": admission_window_schema()
            }
        },
        "additionalProperties": false
    })
}

fn admission_limit_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "kind": {
                "type": "string",
                "enum": ["concurrency", "rate", "token_budget", "monetary_budget"]
            },
            "scope": admission_scope_schema(),
            "limit": { "type": "integer", "minimum": 1 },
            "limit_microusd": { "type": "integer", "minimum": 1 },
            "window_seconds": { "type": "integer", "minimum": 1 },
            "reservation": { "type": "integer", "minimum": 1 }
        },
        "required": ["kind", "scope"],
        "additionalProperties": false
    })
}

fn admission_scope_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "kind": {
                "type": "string",
                "enum": ["global", "workflow", "repository"]
            },
            "value": { "type": "string" }
        },
        "required": ["kind"],
        "additionalProperties": false
    })
}

fn admission_window_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "scope": admission_scope_schema(),
            "timezone": { "type": "string" },
            "weekdays": {
                "type": "array",
                "items": {
                    "type": "string",
                    "enum": [
                        "monday", "tuesday", "wednesday", "thursday", "friday",
                        "saturday", "sunday"
                    ]
                }
            },
            "start_time": { "type": "string" },
            "end_time": { "type": "string" },
            "outside_action": { "type": "string", "enum": ["defer", "deny"] }
        },
        "required": [
            "scope", "timezone", "weekdays", "start_time", "end_time", "outside_action"
        ],
        "additionalProperties": false
    })
}

fn permissive_object_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": true
    })
}

fn github_tokens_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "global_token": { "type": "string" },
            "repository_tokens": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "repository": { "type": "string" },
                        "token": { "type": "string" }
                    },
                    "required": ["repository", "token"],
                    "additionalProperties": false
                }
            }
        },
        "additionalProperties": false
    })
}

fn todoist_token_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "token": { "type": "string" }
        },
        "additionalProperties": false
    })
}

fn openrouter_token_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "token": { "type": "string" }
        },
        "additionalProperties": false
    })
}
