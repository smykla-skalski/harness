use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write as _};
use std::path::{Path, PathBuf};

use fs_err as fs;
use fs2::FileExt;
use serde::Serialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::hooks::protocol::context::{NormalizedEvent, NormalizedHookContext};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::{harness_data_root, project_context_dir, utc_now};

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
    agents_root(project_dir)
        .join(".locks")
        .join(format!("{name}.lock"))
}

fn agent_name(agent: HookAgent) -> &'static str {
    match agent {
        HookAgent::Claude => "claude",
        HookAgent::Codex => "codex",
        HookAgent::Gemini => "gemini",
        HookAgent::Copilot => "copilot",
        HookAgent::OpenCode => "opencode",
    }
}

fn open_lock_file(path: &Path) -> Result<File, CliError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
    }
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(|error| io_err(&error))
}

fn with_lock<T>(
    project_dir: &Path,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let file = open_lock_file(&lock_path(project_dir, name))?;
    file.lock_exclusive().map_err(|error| io_err(&error))?;
    let result = action();
    let unlock = file.unlock().map_err(|error| io_err(&error));
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
        registry
            .current
            .insert(agent_name(agent).to_string(), session_id.to_string());
        registry.updated_at = utc_now();
        write_json_pretty(&path, &registry)
    })
}

pub(crate) fn clear_current_session_id(
    project_dir: &Path,
    agent: HookAgent,
) -> Result<(), CliError> {
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
    agent_hint: Option<HookAgent>,
) -> Result<Option<PathBuf>, CliError> {
    let root = harness_data_root().join("projects");
    if !root.is_dir() {
        return Ok(None);
    }
    let matches = matching_canonical_sessions(&root, session_id, project_hint, agent_hint);
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

fn matching_canonical_sessions(
    root: &Path,
    session_id: &str,
    project_hint: Option<&str>,
    agent_hint: Option<HookAgent>,
) -> Vec<PathBuf> {
    let mut matches = Vec::new();
    for entry in walkdir::WalkDir::new(root).min_depth(4).max_depth(6) {
        let Ok(entry) = entry else {
            continue;
        };
        if canonical_session_matches(&entry, session_id, project_hint, agent_hint) {
            matches.push(entry.path().to_path_buf());
        }
    }
    matches
}

fn canonical_session_matches(
    entry: &walkdir::DirEntry,
    session_id: &str,
    project_hint: Option<&str>,
    agent_hint: Option<HookAgent>,
) -> bool {
    if !entry.file_type().is_file() || entry.file_name() != "raw.jsonl" {
        return false;
    }
    let Some(session_dir) = entry.path().parent() else {
        return false;
    };
    let Some(found_session_id) = session_dir.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    if found_session_id != session_id {
        return false;
    }
    if let Some(agent_hint) = agent_hint {
        let Some(agent_dir) = session_dir.parent().and_then(|path| path.file_name()) else {
            return false;
        };
        if agent_dir != agent_name(agent_hint) {
            return false;
        }
    }
    project_hint.is_none_or(|hint| entry.path().display().to_string().contains(hint))
}

pub(crate) fn project_context_root_from_session_path(path: &Path) -> Option<PathBuf> {
    if path.file_name().and_then(|name| name.to_str()) != Some("raw.jsonl") {
        return None;
    }
    let path_text = path.to_string_lossy();
    if !path_text.contains("/agents/sessions/") {
        return None;
    }
    path.ancestors().nth(5).map(Path::to_path_buf)
}

fn next_sequence(path: &Path) -> Result<u64, CliError> {
    if !path.exists() {
        return Ok(1);
    }
    let file = File::open(path).map_err(|error| io_err(&error))?;
    let reader = BufReader::new(file);
    let mut last = 0;
    for line in reader.lines() {
        let line = line.map_err(|error| io_err(&error))?;
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
        fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| io_err(&error))?;
    writeln!(file, "{line}").map_err(|error| io_err(&error))
}

fn normalized_event_name(event: &NormalizedEvent) -> &'static str {
    match event {
        NormalizedEvent::UserPromptSubmit => "user_prompt_submit",
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
        (NormalizedEvent::UserPromptSubmit, _) => serde_json::json!({
            "role": "user",
            "content": [{
                "type": "text",
                "text": context
                    .agent
                    .as_ref()
                    .and_then(|agent| agent.prompt.clone())
                    .unwrap_or_else(|| normalized_event_name(&context.event).to_string()),
            }],
        }),
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::thread;

    use fs_err as fs;

    fn with_agent_storage_env(body: impl FnOnce(&Path)) {
        let tmp = tempfile::tempdir().unwrap();
        let data_dir = tmp.path().join("xdg_data");
        let project_dir = tmp.path().join("repo");
        fs::create_dir_all(&data_dir).unwrap();
        fs::create_dir_all(&project_dir).unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(data_dir.to_str().unwrap())),
                ("HOME", Some(tmp.path().to_str().unwrap())),
            ],
            || body(&project_dir),
        );
    }

    fn read_ledger_events(project_dir: &Path) -> Vec<AgentLedgerEvent> {
        let ledger = fs::read_to_string(ledger_path(project_dir)).unwrap();
        ledger
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str::<AgentLedgerEvent>(line).unwrap())
            .collect()
    }

    fn read_session_lines(project_dir: &Path, agent: HookAgent, session_id: &str) -> Vec<String> {
        fs::read_to_string(session_file_path(project_dir, agent, session_id))
            .unwrap()
            .lines()
            .map(ToOwned::to_owned)
            .collect()
    }

    #[test]
    fn concurrent_multi_agent_writes_assign_unique_sequences() {
        with_agent_storage_env(|project_dir| {
            thread::scope(|scope| {
                for (agent, session_id) in [
                    (HookAgent::Claude, "claude-a"),
                    (HookAgent::Codex, "codex-a"),
                    (HookAgent::Gemini, "gemini-a"),
                    (HookAgent::Copilot, "copilot-a"),
                ] {
                    scope.spawn(move || {
                        for _ in 0..8 {
                            append_session_marker(project_dir, agent, session_id, "session_start")
                                .unwrap();
                        }
                    });
                }
            });

            let events = read_ledger_events(project_dir);
            assert_eq!(events.len(), 32);

            let sequences: BTreeSet<u64> = events.iter().map(|event| event.sequence).collect();
            assert_eq!(sequences.len(), events.len());
            assert_eq!(sequences.first().copied(), Some(1));
            assert_eq!(sequences.last().copied(), Some(32));

            for (agent, session_id) in [
                (HookAgent::Claude, "claude-a"),
                (HookAgent::Codex, "codex-a"),
                (HookAgent::Gemini, "gemini-a"),
                (HookAgent::Copilot, "copilot-a"),
            ] {
                assert_eq!(read_session_lines(project_dir, agent, session_id).len(), 8);
            }
        });
    }

    #[test]
    fn session_registry_keeps_agent_pointers_independent() {
        with_agent_storage_env(|project_dir| {
            thread::scope(|scope| {
                for (agent, session_id) in [
                    (HookAgent::Claude, "claude-current"),
                    (HookAgent::Codex, "codex-current"),
                    (HookAgent::Gemini, "gemini-current"),
                    (HookAgent::Copilot, "copilot-current"),
                ] {
                    scope.spawn(move || {
                        set_current_session_id(project_dir, agent, session_id).unwrap();
                    });
                }
            });

            assert_eq!(
                current_session_id(project_dir, HookAgent::Claude)
                    .unwrap()
                    .as_deref(),
                Some("claude-current")
            );
            assert_eq!(
                current_session_id(project_dir, HookAgent::Codex)
                    .unwrap()
                    .as_deref(),
                Some("codex-current")
            );
            assert_eq!(
                current_session_id(project_dir, HookAgent::Gemini)
                    .unwrap()
                    .as_deref(),
                Some("gemini-current")
            );
            assert_eq!(
                current_session_id(project_dir, HookAgent::Copilot)
                    .unwrap()
                    .as_deref(),
                Some("copilot-current")
            );

            clear_current_session_id(project_dir, HookAgent::Codex).unwrap();

            assert_eq!(
                current_session_id(project_dir, HookAgent::Codex).unwrap(),
                None
            );
            assert_eq!(
                current_session_id(project_dir, HookAgent::Claude)
                    .unwrap()
                    .as_deref(),
                Some("claude-current")
            );
            assert_eq!(
                current_session_id(project_dir, HookAgent::Copilot)
                    .unwrap()
                    .as_deref(),
                Some("copilot-current")
            );
        });
    }
}

fn io_err(error: &impl ToString) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
}
