use serde_json::{Value, json};

// These bounds come through `daemon::protocol` rather than `crate::task_board`
// because this file also compiles into the standalone `harness-mcp` crate,
// which has no `task_board` module.
use crate::daemon::protocol::{
    TASK_BOARD_LIST_MAX_LIMIT, TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
    ws_methods,
};
use crate::mcp::tool::ToolRegistry;

use super::list_walk::TaskBoardListTool;
use super::support::{TaskBoardToolDescriptor, register_descriptors};

pub(super) fn register(registry: &mut ToolRegistry) {
    // The list endpoint is bounded, so this one tool folds the daemon's pages
    // instead of proxying a single round trip like every descriptor below.
    registry.register(Box::new(TaskBoardListTool::new(list_schema)));
    register_descriptors(
        registry,
        &[
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_CREATE,
                description: "Create a task-board item through the running daemon.",
                input_schema: create_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_GET,
                description: "Fetch one task-board item by id.",
                input_schema: id_only_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POSITION_GET,
                description: "Fetch one task-board item's canonical lane position snapshot.",
                input_schema: id_only_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POSITION_SET,
                description: "Set one task-board item's explicit lane position.",
                input_schema: position_set_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_POSITION_RESET,
                description: "Reset one task-board item to its derived lane position.",
                input_schema: position_reset_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_UPDATE,
                description: "Update a task-board item by id.",
                input_schema: update_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_DELETE,
                description: "Delete a task-board item by id.",
                input_schema: id_only_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_BEGIN,
                description: "Begin planning for a task-board item.",
                input_schema: id_only_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_SUBMIT,
                description: "Submit a task-board plan summary for review.",
                input_schema: plan_submit_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_APPROVE,
                description: "Approve a task-board plan.",
                input_schema: plan_approve_schema,
            },
            TaskBoardToolDescriptor {
                name: ws_methods::TASK_BOARD_PLAN_REVOKE,
                description: "Revoke an approved task-board plan and return it to draft.",
                input_schema: plan_revoke_schema,
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
            "title": { "type": "string", "pattern": "\\S" },
            "body": { "type": "string" },
            "status": { "type": "string" },
            "priority": { "type": "string" },
            "agent_mode": { "type": "string" },
            "estimated_tokens": {
                "type": "integer", "minimum": 1, "maximum": 9_223_372_036_854_775_807_u64
            },
            "estimated_cost_microusd": {
                "type": "integer", "minimum": 1, "maximum": 9_223_372_036_854_775_807_u64
            },
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

/// The daemon refuses a whitespace-only tag and caps how many one read may
/// carry, so the tool advertises both rather than leaving a caller to find
/// them through a failed call.
fn tag_filter_schema() -> Value {
    json!({
        "type": "array",
        "maxItems": TASK_BOARD_LIST_MAX_TAGS,
        "items": { "type": "string", "pattern": "\\S" }
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

fn list_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "status": { "type": "string" },
            "priority": { "type": "string" },
            "agent_mode": { "type": "string" },
            "project_id": { "type": "string" },
            "tags": tag_filter_schema(),
            "query": { "type": "string", "maxLength": TASK_BOARD_LIST_MAX_QUERY_CHARS },
            "limit": {
                "type": "integer", "minimum": 1, "maximum": TASK_BOARD_LIST_MAX_LIMIT
            },
            "cursor": { "type": "string" }
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

fn position_set_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string" },
            "status": { "type": "string" },
            "lane_position": { "type": "integer", "minimum": 0, "maximum": u32::MAX },
            "expected_item_revision": { "type": "integer", "minimum": 0 },
            "expected_items_change_seq": { "type": "integer", "minimum": 0 }
        },
        "required": [
            "id",
            "status",
            "lane_position",
            "expected_item_revision",
            "expected_items_change_seq"
        ],
        "additionalProperties": false
    })
}

fn position_reset_schema() -> Value {
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
            "estimated_tokens": {
                "type": "integer", "minimum": 1, "maximum": 9_223_372_036_854_775_807_u64
            },
            "estimated_cost_microusd": {
                "type": "integer", "minimum": 1, "maximum": 9_223_372_036_854_775_807_u64
            },
            "clear_estimated_tokens": { "type": "boolean" },
            "clear_estimated_cost_microusd": { "type": "boolean" },
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
        "allOf": [
            {
                "not": {
                    "properties": { "clear_estimated_tokens": { "const": true } },
                    "required": ["estimated_tokens", "clear_estimated_tokens"]
                }
            },
            {
                "not": {
                    "properties": {
                        "clear_estimated_cost_microusd": { "const": true }
                    },
                    "required": [
                        "estimated_cost_microusd", "clear_estimated_cost_microusd"
                    ]
                }
            }
        ],
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        TASK_BOARD_LIST_MAX_LIMIT, TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
        create_schema, list_schema, update_schema,
    };

    /// A `minLength` of 1 would still advertise a whitespace-only title as
    /// valid, and the daemon trims before refusing one, so the schema has to
    /// demand a visible character or the client learns of the mismatch only
    /// from a failed call.
    #[test]
    fn create_offers_a_starting_status_and_demands_a_title() {
        let schema = create_schema();

        assert_eq!(schema["properties"]["status"]["type"], json!("string"));
        assert_eq!(schema["properties"]["title"]["pattern"], json!("\\S"));
        assert_eq!(schema["required"], json!(["title"]));
    }

    #[test]
    fn estimate_schemas_advertise_the_storage_bounds() {
        for schema in [create_schema(), update_schema()] {
            let properties = &schema["properties"];
            for field in ["estimated_tokens", "estimated_cost_microusd"] {
                assert_eq!(properties[field]["minimum"], json!(1));
                assert_eq!(properties[field]["maximum"], json!(i64::MAX));
            }
        }
    }

    /// The daemon refuses an out-of-range page instead of clamping it, so the
    /// advertised bounds have to match or a caller learns of the mismatch only
    /// from a failed call.
    #[test]
    fn list_offers_every_facet_and_advertises_the_page_bounds() {
        let schema = list_schema();
        let properties = &schema["properties"];

        for facet in ["status", "priority", "agent_mode", "project_id", "cursor"] {
            assert_eq!(properties[facet]["type"], json!("string"), "{facet}");
        }
        assert_eq!(properties["tags"]["type"], json!("array"));
        assert_eq!(properties["tags"]["maxItems"], json!(TASK_BOARD_LIST_MAX_TAGS));
        assert_eq!(properties["tags"]["items"]["pattern"], json!("\\S"));
        assert_eq!(
            properties["query"]["maxLength"],
            json!(TASK_BOARD_LIST_MAX_QUERY_CHARS)
        );
        assert_eq!(properties["limit"]["minimum"], json!(1));
        assert_eq!(
            properties["limit"]["maximum"],
            json!(TASK_BOARD_LIST_MAX_LIMIT)
        );
        assert_eq!(schema["required"], json!(null));
    }

    #[test]
    fn update_schema_rejects_set_and_clear_combinations() {
        let schema = update_schema();

        assert_eq!(schema["allOf"].as_array().map(Vec::len), Some(2));
        assert_eq!(
            schema["allOf"][0]["not"]["required"],
            json!(["estimated_tokens", "clear_estimated_tokens"])
        );
        assert_eq!(
            schema["allOf"][1]["not"]["required"],
            json!(["estimated_cost_microusd", "clear_estimated_cost_microusd"])
        );
    }
}
