//! Comparison helpers for the task-board HTTP/WebSocket parity tests.
//!
//! The two legs of a parity check are produced by separate calls a moment
//! apart, so ids, revisions, and timestamps differ even when the payloads are
//! equivalent. These shape both sides into the form the assertions compare,
//! replacing only fields that are genuinely non-deterministic - a leg that
//! dropped a field entirely must still fail rather than be masked.

use std::collections::BTreeMap;

use serde_json::{Value, json};

pub(in crate::daemon::http::tests) fn planning_path(template: &str, id: &str) -> String {
    template.replace("{item_id}", id)
}

pub(in crate::daemon::http::tests) fn normalized_planning_response(value: &Value) -> Value {
    let mut value = value.clone();
    value["transition"]["board_item_id"] = json!("normalized-item");
    value["item"]["id"] = json!("normalized-item");
    // The HTTP and WS legs each stamp `updated_at` from their own `utc_now()`
    // call a moment apart, so it can tick over a second boundary under load
    // even though the two responses are otherwise structurally equivalent.
    // Only overwrite it when present, so a leg that dropped the field
    // entirely still shows up as a real mismatch instead of being masked.
    if let Some(item) = value["item"].as_object_mut()
        && item.contains_key("updated_at")
    {
        item["updated_at"] = json!("normalized-timestamp");
    }
    value
}

pub(in crate::daemon::http::tests) fn normalized_policy(value: &Value) -> Value {
    let mut value = value.clone();
    replace_dynamic_policy_fields(&mut value);
    value
}

pub(in crate::daemon::http::tests) fn normalized_policy_workspace(value: &Value) -> Value {
    let mut value = value.clone();
    replace_dynamic_policy_fields(&mut value);

    let mut canvas_ids = BTreeMap::new();
    if let Some(canvases) = value.get_mut("canvases").and_then(Value::as_array_mut) {
        for (index, canvas) in canvases.iter_mut().enumerate() {
            let normalized_id = format!("canvas-{index}");
            let Some(canvas_object) = canvas.as_object_mut() else {
                continue;
            };

            for field in ["id", "canvas_id"] {
                let Some(original_id) = canvas_object
                    .get(field)
                    .and_then(Value::as_str)
                    .map(ToString::to_string)
                else {
                    continue;
                };
                canvas_ids.insert(original_id, normalized_id.clone());
            }

            canvas_object.insert("id".into(), json!(normalized_id));
            if canvas_object.contains_key("canvas_id") {
                canvas_object.insert("canvas_id".into(), json!(normalized_id));
            }
            canvas_object.insert("created_at".into(), json!("<dynamic>"));
            canvas_object.insert("updated_at".into(), json!("<dynamic>"));
        }
    }

    if let Some(active_canvas_id) = value
        .get("active_canvas_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
    {
        let normalized = canvas_ids
            .get(&active_canvas_id)
            .cloned()
            .unwrap_or_else(|| "<dynamic>".to_string());
        value["active_canvas_id"] = json!(normalized);
    }

    value
}

fn replace_dynamic_policy_fields(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, nested) in map {
                if matches!(
                    key.as_str(),
                    "active_revision"
                        | "latest_trace_id"
                        | "live_updated_at"
                        | "revision"
                        | "simulated_at"
                        | "trace_id"
                ) {
                    *nested = json!("<dynamic>");
                } else {
                    replace_dynamic_policy_fields(nested);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                replace_dynamic_policy_fields(item);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {}
    }
}
