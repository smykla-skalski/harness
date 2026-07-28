use serde_json::{Value, json};

use crate::types::SessionMetrics;
use harness_kernel::errors::{CliError, CliErrorKind};

// v10 onward lives in its own file: the agent-record fixups they run (legacy
// runtime/status shapes, managed-agent identity flattening) are a distinct,
// larger chunk of logic than the flat schema bumps above, and splitting kept
// this file under the repo's line-count convention.
mod agent_field_migrations;
pub use agent_field_migrations::{
    migrate_v10_to_v11, migrate_v11_to_v12, migrate_v12_to_v13, migrate_v13_to_v14,
};

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v1_to_v2(mut value: Value) -> Result<Value, CliError> {
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

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v2_to_v3(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(3));
    object
        .entry("pending_leader_transfer".to_string())
        .or_insert(Value::Null);

    Ok(value)
}

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v3_to_v4(mut value: Value) -> Result<Value, CliError> {
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

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v4_to_v5(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(5));
    Ok(value)
}

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v5_to_v6(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(6));
    Ok(value)
}

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v6_to_v7(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(7));
    object.entry("policy".to_string()).or_insert(json!({
        "leader_join": {
            "require_explicit_fallback_role": true
        },
        "auto_promotion": {
            "role_order": ["improver", "reviewer", "observer", "worker"],
            "priority_preset_id": "swarm-default"
        },
        "degraded_recovery": {
            "preset_id": "swarm-default",
            "manual_recovery_allowed": true
        }
    }));

    Ok(value)
}

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v7_to_v8(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(8));
    object
        .entry("project_name".to_string())
        .or_insert(json!(""));
    object
        .entry("worktree_path".to_string())
        .or_insert(json!(""));
    object.entry("shared_path".to_string()).or_insert(json!(""));
    object.entry("origin_path".to_string()).or_insert(json!(""));
    object.entry("branch_ref".to_string()).or_insert(json!(""));

    Ok(value)
}

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v8_to_v9(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };
    object.insert("schema_version".to_string(), json!(9));
    Ok(value)
}

/// # Errors
/// Returns `CliError` if `value` is not a JSON object.
pub fn migrate_v9_to_v10(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };
    object.insert("schema_version".to_string(), json!(10));
    Ok(value)
}
