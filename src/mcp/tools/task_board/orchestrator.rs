use serde_json::{Value, json};

use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardTodoistTokenSyncRequest, ws_methods,
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
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
                description: "Read task-board orchestrator status from the daemon.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_START,
                description: "Start the task-board orchestrator.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
                description: "Stop the task-board orchestrator.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
                description: "Run one task-board orchestrator tick.",
                input_schema: dispatch_schema,
                normalize: validate_params::<TaskBoardOrchestratorRunOnceRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
                description: "Read task-board orchestrator settings.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
                description: "Update task-board orchestrator settings.",
                input_schema: settings_update_schema,
                normalize: validate_params::<TaskBoardOrchestratorSettingsUpdateRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
                description: "Read task-board git runtime configuration.",
                input_schema: empty_schema,
                normalize: validate_empty_object,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
                description: "Update task-board git runtime configuration.",
                input_schema: permissive_object_schema,
                normalize: validate_params::<TaskBoardGitRuntimeConfig>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
                description: "Sync task-board GitHub tokens into daemon runtime state.",
                input_schema: github_tokens_schema,
                normalize: validate_params::<TaskBoardGitHubTokensSyncRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
                description: "Sync the task-board Todoist token into daemon runtime state.",
                input_schema: todoist_token_schema,
                normalize: validate_params::<TaskBoardTodoistTokenSyncRequest>,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
                description: "Discover system-level git identity defaults (git config, gh CLI, ~/.ssh, env vars).",
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
            "policy_version": { "type": "string" }
        },
        "additionalProperties": true
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
