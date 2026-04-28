use serde_json::{Value, json};

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

pub(super) fn migrate_v6_to_v7(mut value: Value) -> Result<Value, CliError> {
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

pub(super) fn migrate_v7_to_v8(mut value: Value) -> Result<Value, CliError> {
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

pub(super) fn migrate_v8_to_v9(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };
    object.insert("schema_version".to_string(), json!(9));
    Ok(value)
}

pub(super) fn migrate_v9_to_v10(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };
    object.insert("schema_version".to_string(), json!(10));
    Ok(value)
}

/// Chunk-2 migrator: tag legacy bare-string `runtime` values and upgrade the
/// only status variant that gained payload fields.
///
/// - `runtime: "claude"` → `runtime: { "kind": "tui", "id": "claude" }` for
///   known TUI names; unknown legacy strings (forward-rolled state) become
///   `{ "kind": "acp", "id": "<value>" }` so the daemon does not crash on
///   load.
/// - `status: "disconnected"` → `status: { "state": "disconnected", "reason":
///   { "kind": "unknown" } }`. Other status strings (`active`, `idle`,
///   `awaiting_review`, `removed`) intentionally stay bare strings because
///   they did not gain payload fields.
pub(super) fn migrate_v10_to_v11(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };
    object.insert("schema_version".to_string(), json!(11));

    if let Some(agents) = object.get_mut("agents").and_then(Value::as_object_mut) {
        for agent in agents.values_mut() {
            let Some(agent_object) = agent.as_object_mut() else {
                continue;
            };
            migrate_runtime_field(agent_object);
            migrate_status_field(agent_object);
        }
    }

    Ok(value)
}

fn migrate_runtime_field(agent: &mut serde_json::Map<String, Value>) {
    let Some(runtime) = agent.get("runtime") else {
        return;
    };
    if let Some(name) = runtime.as_str() {
        // FROZEN v10 universe: this list represents every TUI runtime that
        // existed when schema v10 was the steady state. Do NOT extend it
        // when new TUI agents are added — new agents land in their own
        // migrator step and a v10 state file by definition cannot reference
        // them. Drift here would silently re-classify legitimate ACP ids
        // that happen to match a future TUI name.
        let kind = match name {
            "claude" | "codex" | "gemini" | "copilot" | "vibe" | "opencode" => "tui",
            _ => "acp",
        };
        agent.insert("runtime".to_string(), json!({ "kind": kind, "id": name }));
    }
}

fn migrate_status_field(agent: &mut serde_json::Map<String, Value>) {
    let Some(status) = agent.get("status") else {
        return;
    };
    // Bare-string non-disconnected variants stay bare (the new
    // `AgentStatus` deserializer accepts both shapes); only `"disconnected"`
    // is upgraded so the new `reason` and `stderr_tail` slots exist on disk.
    if status.as_str() == Some("disconnected") {
        agent.insert(
            "status".to_string(),
            json!({
                "state": "disconnected",
                "reason": { "kind": "unknown" },
            }),
        );
    }
}
