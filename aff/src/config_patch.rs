use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::hook_agent::HookAgent;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    Apply,
    Check,
}

pub fn sync_runtime_configs(
    project_dir: &Path,
    agents: &[HookAgent],
    skip_runtime_hooks: &[HookAgent],
    mode: SyncMode,
) -> Result<Vec<PathBuf>, String> {
    let mut processed = Vec::new();
    let mut drift = Vec::new();

    for &agent in agents {
        if skip_runtime_hooks.contains(&agent) {
            continue;
        }

        let path = agent.config_path(project_dir);
        let current = fs::read_to_string(&path).map_err(|error| {
            format!(
                "expected harness-generated runtime config at {} before aff patching: {error}",
                path.display()
            )
        })?;
        let patched = patch_runtime_config(agent, &current)?;

        if patched != current {
            match mode {
                SyncMode::Apply => {
                    fs::write(&path, patched).map_err(|error| {
                        format!(
                            "failed to write patched runtime config {}: {error}",
                            path.display()
                        )
                    })?;
                }
                SyncMode::Check => drift.push(path.clone()),
            }
        }

        processed.push(path);
    }

    if !drift.is_empty() {
        let paths = drift
            .iter()
            .map(|path| format!("- {}", path.display()))
            .collect::<Vec<_>>()
            .join("\n");
        return Err(format!(
            "aff runtime config drift detected:\n{paths}\nRerun `aff setup agents generate` after the harness setup step."
        ));
    }

    Ok(processed)
}

fn patch_runtime_config(agent: HookAgent, current: &str) -> Result<String, String> {
    let mut root: Value = serde_json::from_str(current)
        .map_err(|error| format!("invalid runtime config JSON: {error}"))?;

    match agent {
        HookAgent::Claude => {
            patch_nested_hook_config(&mut root, agent, "PreToolUse", "SessionStart", None)
        }
        HookAgent::Codex => {
            patch_nested_hook_config(&mut root, agent, "PreToolUse", "SessionStart", Some(10))
        }
        HookAgent::Gemini => {
            patch_nested_hook_config(&mut root, agent, "BeforeTool", "SessionStart", Some(5000))
        }
        HookAgent::Copilot => patch_copilot_config(&mut root, agent),
        HookAgent::Vibe | HookAgent::OpenCode => patch_registration_config(&mut root, agent),
    }?;

    serde_json::to_string_pretty(&root)
        .map_err(|error| format!("failed to encode patched runtime config: {error}"))
}

fn patch_nested_hook_config(
    root: &mut Value,
    agent: HookAgent,
    pre_tool_event: &'static str,
    session_start_event: &'static str,
    timeout: Option<u64>,
) -> Result<(), String> {
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| "invalid runtime config: root must be a JSON object".to_string())?;
    let hooks = ensure_object(root_object, "hooks", "runtime config hooks")?;

    patch_nested_event(
        hooks,
        pre_tool_event,
        agent.repo_policy_command().as_str(),
        Some(".*"),
        timeout,
    )?;
    patch_nested_event(
        hooks,
        session_start_event,
        agent.session_start_command().as_str(),
        None,
        timeout,
    )?;
    Ok(())
}

fn patch_copilot_config(root: &mut Value, agent: HookAgent) -> Result<(), String> {
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| "invalid runtime config: root must be a JSON object".to_string())?;
    let hooks = ensure_object(root_object, "hooks", "runtime config hooks")?;

    patch_copilot_event(hooks, "preToolUse", agent.repo_policy_command().as_str())?;
    patch_copilot_event(
        hooks,
        "sessionStart",
        agent.session_start_command().as_str(),
    )?;
    Ok(())
}

fn patch_registration_config(root: &mut Value, agent: HookAgent) -> Result<(), String> {
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| "invalid runtime config: root must be a JSON object".to_string())?;
    let registrations = ensure_array(root_object, "registrations", "runtime registrations")?;

    registrations.retain(|entry| {
        entry
            .get("name")
            .and_then(Value::as_str)
            .is_none_or(|name| name != "aff-repo-policy" && name != "aff-session-start")
    });
    registrations.push(json!({
        "name": "aff-repo-policy",
        "event": "tool.execute.before",
        "command": agent.repo_policy_command(),
        "matcher": ".*"
    }));
    registrations.push(json!({
        "name": "aff-session-start",
        "event": "session.created",
        "command": agent.session_start_command()
    }));
    Ok(())
}

fn patch_nested_event(
    hooks: &mut Map<String, Value>,
    event_name: &'static str,
    command: &str,
    matcher: Option<&'static str>,
    timeout: Option<u64>,
) -> Result<(), String> {
    let event_hooks = ensure_array(hooks, event_name, event_name)?;
    event_hooks.retain(|entry| !nested_entry_matches_command(entry, command));

    let mut command_hook = Map::new();
    command_hook.insert("type".to_string(), Value::String("command".to_string()));
    command_hook.insert("command".to_string(), Value::String(command.to_string()));
    if let Some(timeout) = timeout {
        command_hook.insert(
            "timeout".to_string(),
            Value::Number(serde_json::Number::from(timeout)),
        );
    }

    let mut registration = Map::new();
    if let Some(matcher) = matcher {
        registration.insert("matcher".to_string(), Value::String(matcher.to_string()));
    }
    registration.insert(
        "hooks".to_string(),
        Value::Array(vec![Value::Object(command_hook)]),
    );
    event_hooks.push(Value::Object(registration));
    Ok(())
}

fn patch_copilot_event(
    hooks: &mut Map<String, Value>,
    event_name: &'static str,
    command: &str,
) -> Result<(), String> {
    let event_hooks = ensure_array(hooks, event_name, event_name)?;
    event_hooks.retain(|entry| {
        entry
            .get("bash")
            .and_then(Value::as_str)
            .is_none_or(|existing| existing != command)
    });
    event_hooks.push(json!({
        "type": "command",
        "bash": command,
        "cwd": ".",
        "timeoutSec": 30
    }));
    Ok(())
}

fn nested_entry_matches_command(entry: &Value, command: &str) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks.iter().any(|hook| {
                hook.get("command")
                    .and_then(Value::as_str)
                    .is_some_and(|existing| existing == command)
            })
        })
}

fn ensure_object<'a>(
    parent: &'a mut Map<String, Value>,
    key: &str,
    context: &str,
) -> Result<&'a mut Map<String, Value>, String> {
    let value = parent
        .entry(key.to_string())
        .or_insert_with(|| Value::Object(Map::new()));
    value
        .as_object_mut()
        .ok_or_else(|| format!("invalid runtime config: expected {context} to be an object"))
}

fn ensure_array<'a>(
    parent: &'a mut Map<String, Value>,
    key: &str,
    context: &str,
) -> Result<&'a mut Vec<Value>, String> {
    let value = parent
        .entry(key.to_string())
        .or_insert_with(|| Value::Array(Vec::new()));
    value
        .as_array_mut()
        .ok_or_else(|| format!("invalid runtime config: expected {context} to be an array"))
}
