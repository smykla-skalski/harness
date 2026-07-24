use serde_json::{Value, json};

use crate::daemon::protocol::ws_methods;
use crate::mcp::tool::ToolRegistry;

use super::support::{TaskBoardToolDescriptor, register_descriptors};

pub(super) fn register(registry: &mut ToolRegistry) {
    register_descriptors(
        registry,
        &[
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_GET,
                description: "Fetch one task-board item's current triage decision.",
                input_schema: id_only_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_HISTORY,
                description: "Page one task-board item's triage decision history, newest first.",
                input_schema: triage_history_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET,
                description: "Override the triage verdict for one task-board item.",
                input_schema: override_set_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR,
                description: "Clear a task-board item's triage override and return it to the \
                              automatic verdict.",
                input_schema: override_clear_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_GET,
                description: "Fetch the current triage rule-set draft.",
                input_schema: empty_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_SAVE,
                description: "Save the triage rule-set draft without activating it.",
                input_schema: rules_draft_save_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_RULES_PREVIEW,
                description: "Preview what a triage rule set would decide, persisting nothing.",
                input_schema: rules_preview_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_RULES_ACTIVATE,
                description: "Activate a triage rule set, or deactivate back to the built-in \
                              evaluator by omitting `rules`.",
                input_schema: rules_activate_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_RULES_REVISIONS,
                description: "List triage rule-set revisions, newest first.",
                input_schema: limit_only_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_TRIAGE_RULES_AUDIT,
                description: "List triage rule-set audit entries, newest first.",
                input_schema: limit_only_schema,
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

// The upper bound on `limit` lives with the page validation in the daemon's
// protocol crate, which this shared MCP source cannot reach. Advertising only
// the lower bound keeps one owner for the ceiling instead of a copy that rots.
fn triage_history_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "before_generation": { "type": "integer", "minimum": 1 },
            "limit": { "type": "integer", "minimum": 1 }
        },
        "required": ["id"],
        "additionalProperties": false
    })
}

fn override_set_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "verdict": { "type": "string", "enum": ["todo", "undecided"] },
            "reason": { "type": "string" },
            "expected_item_revision": { "type": "integer", "minimum": 0 },
            "expected_items_change_seq": { "type": "integer", "minimum": 0 }
        },
        "required": [
            "id",
            "verdict",
            "expected_item_revision",
            "expected_items_change_seq"
        ],
        "additionalProperties": false
    })
}

fn override_clear_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "expected_item_revision": { "type": "integer", "minimum": 0 },
            "expected_items_change_seq": { "type": "integer", "minimum": 0 }
        },
        "required": ["id", "expected_item_revision", "expected_items_change_seq"],
        "additionalProperties": false
    })
}

// `rules` stays an opaque object here. The rule set is a versioned document the
// daemon validates on arrival, and mirroring its shape into a hand-written
// schema would only add a second definition to keep in sync.
fn rules_draft_save_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "rules": { "type": "object" },
            "expected_revision": { "type": "integer", "minimum": 0 }
        },
        "required": ["rules"],
        "additionalProperties": false
    })
}

fn rules_preview_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "rules": { "type": "object" }
        },
        "required": ["rules"],
        "additionalProperties": false
    })
}

fn rules_activate_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "rules": { "type": "object" },
            "expected_active_revision": { "type": "integer", "minimum": 0 }
        },
        "additionalProperties": false
    })
}

fn limit_only_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "limit": { "type": "integer", "minimum": 1 }
        },
        "additionalProperties": false
    })
}
