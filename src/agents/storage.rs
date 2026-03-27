use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write as _};
use std::path::{Path, PathBuf};

use fs2::FileExt;
use fs_err as fs;
use serde::Serialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::{project_context_dir, utc_now};

use super::types::{AgentLedgerEvent, AgentSessionRegistry};

fn agents_root(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir).join("agents")
}

fn sessions_root(project_dir: &Path) -> PathBuf {
    agents_root(project_dir).join("sessions")
}

fn ledger_path(project_dir: &Path) -> PathBuf {
    agents_root(project_dir).join("ledger").join("events.jsonl")
}

fn session_registry_path(project_dir: &Path) -> PathBuf {
    sessions_root(project_dir).join("current.json")
}

fn session_file_path(project_dir: &Path, agent: HookAgent, session_id: &str) -> PathBuf {
    sessions_root(project_dir)
        .join(agent_name(agent))
        .join(session_id)
        .join("raw.jsonl")
}

fn lock_path(project_dir: &Path, name: &str) -> PathBuf {
    agents_root(project_dir).join(".locks").join(format!("{name}.lock"))
}

fn agent_name(agent: HookAgent) -> &'static str {
    match agent {
        HookAgent::Claude => "claude",
        HookAgent::Codex => "codex",
        HookAgent::Gemini => "gemini",
        HookAgent::Copilot => "copilot",
    }
}

fn open_lock_file(path: &Path) -> Result<File, CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_err)?;
    }
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(io_err)
}

fn with_lock<T>(
    project_dir: &Path,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let file = open_lock_file(&lock_path(project_dir, name))?;
    file.lock_exclusive().map_err(io_err)?;
    let result = action();
    let unlock = file.unlock().map_err(io_err);
    match (result, unlock) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(error), Ok(()) | Err(_)) | (Ok(_), Err(error)) => Err(error),
    }
}

pub(crate) fn current_session_id(
    project_dir: &Path,
    agent: HookAgent,
) -> Result<Option<String>, CliError> {
    let path = session_registry_path(project_dir);
    if !path.exists() {
        return Ok(None);
    }
    let registry: AgentSessionRegistry = read_json_typed(&path)?;
    Ok(registry.current.get(agent_name(agent)).cloned())
}

pub(crate) fn set_current_session_id(
    project_dir: &Path,
    agent: HookAgent,
    session_id: &str,
) -> Result<(), CliError> {
    with_lock(project_dir, "sessions", || {
        let path = session_registry_path(project_dir);
        let mut registry = if path.exists() {
            read_json_typed::<AgentSessionRegistry>(&path)?
        } else {
            AgentSessionRegistry::default()
        };
        registry.current.insert(
            agent_name(agent).to_string(),
            session_id.to_string(),
        );
        registry.updated_at = utc_now();
        write_json_pretty(&path, &registry)
    })
}

pub(crate) fn clear_current_session_id(project_dir: &Path, agent: HookAgent) -> Result<(), CliError> {
    with_lock(project_dir, "sessions", || {
        let path = session_registry_path(project_dir);
        let mut registry = if path.exists() {
            read_json_typed::<AgentSessionRegistry>(&path)?
        } else {
            AgentSessionRegistry::default()
        };
        registry.current.remove(agent_name(agent));
        registry.updated_at = utc_now();
        write_json_pretty(&path, &registry)
    })
}

pub(crate) fn append_hook_event(
    project_dir: &Path,
    agent: HookAgent,
    session_id: &str,
    skill: &str,
    hook_name: &str,
    context: &NormalizedHookContext,
    result: &NormalizedHookResult,
) -> Result<(), CliError> {
    with_lock(project_dir, "ledger", || {
        let ledger = ledger_path(project_dir);
        let sequence = next_sequence(&ledger)?;
        let recorded_at = utc_now();
        let event = AgentLedgerEvent {
            sequence,
            recorded_at: recorded_at.clone(),
            agent: agent_name(agent).to_string(),
            session_id: session_id.to_string(),
            skill: skill.to_string(),
            event: normalized_event_name(&context.event).to_string(),
            hook: hook_name.to_string(),
            decision: result.code.clone(),
            cwd: project_dir.display().to_string(),
            payload: render_canonical_line(&recorded_at, skill, hook_name, context, result)?,
        };
        append_json_line(&ledger, &event)?;
        append_text_line(
            &session_file_path(project_dir, agent, session_id),
            &serde_json::to_string(&event.payload)
                .expect("typed canonical session payload serializes"),
        )?;
        Ok(())
    })
}

pub(crate) fn append_session_marker(
    project_dir: &Path,
    agent: HookAgent,
    session_id: &str,
    event_name: &str,
) -> Result<(), CliError> {
    with_lock(project_dir, "ledger", || {
        let ledger = ledger_path(project_dir);
        let sequence = next_sequence(&ledger)?;
        let recorded_at = utc_now();
        let payload = serde_json::json!({
            "timestamp": recorded_at,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "text",
                        "text": format!("{event_name}:{}", agent_name(agent))
                    }
                ]
            },
            "harness": {
                "agent": agent_name(agent),
                "session_id": session_id,
                "event": event_name,
            }
        });
        let event = AgentLedgerEvent {
            sequence,
            recorded_at: utc_now(),
            agent: agent_name(agent).to_string(),
            session_id: session_id.to_string(),
            skill: "agents".to_string(),
            event: event_name.to_string(),
            hook: event_name.to_string(),
            decision: None,
            cwd: project_dir.display().to_string(),
            payload: payload.clone(),
        };
        append_json_line(&ledger, &event)?;
        append_text_line(
            &session_file_path(project_dir, agent, session_id),
            &serde_json::to_string(&payload).expect("typed session marker serializes"),
        )?;
        Ok(())
    })
}

pub(crate) fn find_canonical_session(
    session_id: &str,
    project_hint: Option<&str>,
) -> Result<Option<PathBuf>, CliError> {
    let root = crate::workspace::harness_data_root().join("projects");
    if !root.is_dir() {
        return Ok(None);
    }
    let mut matches = Vec::new();
    for entry in walkdir::WalkDir::new(&root).min_depth(4).max_depth(6) {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        if !entry.file_type().is_file() || entry.file_name() != "raw.jsonl" {
            continue;
        }
        let Some(session_dir) = entry.path().parent() else {
            continue;
        };
        let Some(found_session_id) = session_dir.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if found_session_id != session_id {
            continue;
        }
        if let Some(hint) = project_hint {
            let path_text = entry.path().display().to_string();
            if !path_text.contains(hint) {
                continue;
            }
        }
        matches.push(entry.path().to_path_buf());
    }
    if matches.is_empty() {
        return Ok(None);
    }
    if matches.len() == 1 {
        return Ok(matches.into_iter().next());
    }
    Err(CliErrorKind::session_ambiguous(format!(
        "session '{session_id}' found in multiple harness agent ledgers"
    ))
    .into())
}

fn next_sequence(path: &Path) -> Result<u64, CliError> {
    if !path.exists() {
        return Ok(1);
    }
    let file = File::open(path).map_err(io_err)?;
    let reader = BufReader::new(file);
    let mut last = 0;
    for line in reader.lines() {
        let line = line.map_err(io_err)?;
        if line.trim().is_empty() {
            continue;
        }
        let event: AgentLedgerEvent = serde_json::from_str(&line).map_err(|error| {
            CliErrorKind::session_parse_error(format!("invalid agent ledger entry: {error}"))
        })?;
        last = event.sequence;
    }
    Ok(last.saturating_add(1))
}

fn append_json_line<T>(path: &Path, payload: &T) -> Result<(), CliError>
where
    T: Serialize,
{
    let line = serde_json::to_string(payload)
        .map_err(|error| CliErrorKind::serialize(format!("agent ledger event: {error}")))?;
    append_text_line(path, &line)
}

fn append_text_line(path: &Path, line: &str) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_err)?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(io_err)?;
    writeln!(file, "{line}").map_err(io_err)
}

fn normalized_event_name(event: &NormalizedEvent) -> &'static str {
    match event {
        NormalizedEvent::BeforeToolUse => "before_tool_use",
        NormalizedEvent::AfterToolUse => "after_tool_use",
        NormalizedEvent::AfterToolUseFailure => "after_tool_use_failure",
        NormalizedEvent::SessionStart => "session_start",
        NormalizedEvent::SessionEnd => "session_end",
        NormalizedEvent::AgentStart => "agent_start",
        NormalizedEvent::AgentStop => "agent_stop",
        NormalizedEvent::SubagentStart => "subagent_start",
        NormalizedEvent::SubagentStop => "subagent_stop",
        NormalizedEvent::BeforeCompaction => "before_compaction",
        NormalizedEvent::AfterCompaction => "after_compaction",
        NormalizedEvent::Notification | NormalizedEvent::AgentSpecific(_) => "notification",
    }
}

fn render_canonical_line(
    recorded_at: &str,
    skill: &str,
    hook_name: &str,
    context: &NormalizedHookContext,
    result: &NormalizedHookResult,
) -> Result<Value, CliError> {
    let message = match (&context.event, context.tool.as_ref()) {
        (NormalizedEvent::BeforeToolUse, Some(tool)) => serde_json::json!({
            "role": "assistant",
            "content": [{
                "type": "tool_use",
                "id": format!("{}-{}", skill, hook_name),
                "name": tool.original_name,
                "input": tool.input_raw,
            }],
        }),
        (NormalizedEvent::AfterToolUse | NormalizedEvent::AfterToolUseFailure, Some(tool)) => {
            let response = tool.response.clone().unwrap_or(Value::Null);
            serde_json::json!({
                "role": "user",
                "content": [{
                    "type": "tool_result",
                    "tool_name": tool.original_name,
                    "content": serde_json::to_string(&response)
                        .map_err(|error| CliErrorKind::serialize(format!("tool response: {error}")))?,
                    "is_error": matches!(context.event, NormalizedEvent::AfterToolUseFailure),
                    "raw": response,
                }],
            })
        }
        _ => serde_json::json!({
            "role": "assistant",
            "content": [{
                "type": "text",
                "text": result
                    .reason
                    .clone()
                    .or_else(|| context.agent.as_ref().and_then(|agent| agent.prompt.clone()))
                    .unwrap_or_else(|| normalized_event_name(&context.event).to_string()),
            }],
        }),
    };

    Ok(serde_json::json!({
        "timestamp": recorded_at,
        "message": message,
        "harness": {
            "event": normalized_event_name(&context.event),
            "skill": skill,
            "hook": hook_name,
            "decision": result.code,
        }
    }))
}

fn io_err(error: impl ToString) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
}
