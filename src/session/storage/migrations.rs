use serde_json::{json, Value};

use crate::errors::{CliError, CliErrorKind};
use crate::session::types::SessionMetrics;

pub(super) fn migrate_v1_to_v2(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(2));
    object
        .entry("archived_at".to_string())
        .or_insert(Value::Null);
    object
        .entry("last_activity_at".to_string())
        .or_insert(Value::Null);
    object
        .entry("observe_id".to_string())
        .or_insert(Value::Null);
    object.entry("metrics".to_string()).or_insert(
        serde_json::to_value(SessionMetrics::default()).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("session metrics migration: {error}"))
        })?,
    );

    if let Some(agents) = object.get_mut("agents").and_then(Value::as_object_mut) {
        for agent in agents.values_mut() {
            if let Some(agent_object) = agent.as_object_mut() {
                let runtime_name = agent_object
                    .get("runtime")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_string();
                agent_object
                    .entry("last_activity_at".to_string())
                    .or_insert(Value::Null);
                agent_object
                    .entry("current_task_id".to_string())
                    .or_insert(Value::Null);
                agent_object
                    .entry("runtime_capabilities".to_string())
                    .or_insert(json!({
                        "runtime": runtime_name,
                        "supports_native_transcript": false,
                        "supports_signal_delivery": false,
                        "supports_context_injection": false,
                        "typical_signal_latency_seconds": 0,
                        "hook_points": [],
                    }));
            }
        }
    }

    if let Some(tasks) = object.get_mut("tasks").and_then(Value::as_object_mut) {
        for task in tasks.values_mut() {
            if let Some(task_object) = task.as_object_mut() {
                task_object
                    .entry("suggested_fix".to_string())
                    .or_insert(Value::Null);
                task_object
                    .entry("source".to_string())
                    .or_insert(json!("manual"));
                task_object
                    .entry("blocked_reason".to_string())
                    .or_insert(Value::Null);
                task_object
                    .entry("completed_at".to_string())
                    .or_insert(Value::Null);
                task_object
                    .entry("checkpoint_summary".to_string())
                    .or_insert(Value::Null);
            }
        }
    }

    Ok(value)
}

pub(super) fn migrate_v2_to_v3(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(3));
    object
        .entry("pending_leader_transfer".to_string())
        .or_insert(Value::Null);

    Ok(value)
}

pub(super) fn migrate_v3_to_v4(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    let title = object
        .get("title")
        .cloned()
        .unwrap_or_else(|| object.get("context").cloned().unwrap_or_else(|| json!("")));
    object.insert("schema_version".to_string(), json!(4));
    object.insert("title".to_string(), title);

    Ok(value)
}

pub(super) fn migrate_v4_to_v5(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(5));
    Ok(value)
}

pub(super) fn migrate_v5_to_v6(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(6));
    Ok(value)
}
