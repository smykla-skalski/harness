use std::fs;
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::agents::runtime::{
    AgentRuntime, event::ConversationEvent, parse_canonical_conversation_line, runtime_for_name,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::session::storage;
use crate::session::types::{SessionLogEntry, SessionState, TaskCheckpoint};
use crate::workspace::project_context_dir;

use super::io::{for_each_nonempty_line, read_json_lines};
use super::paths::{
    agent_transcript_path, session_log_path, session_state_path, task_checkpoints_path,
};
use super::projects::discover_projects;
use super::{DiscoveredProject, ResolvedSession};

#[derive(Debug, Deserialize)]
struct LedgerEventLine {
    sequence: u64,
    recorded_at: String,
    agent: String,
    session_id: String,
    payload: Value,
}

/// Discover every session reachable from all harness project contexts.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn discover_sessions(include_all: bool) -> Result<Vec<ResolvedSession>, CliError> {
    discover_sessions_for(&discover_projects()?, include_all)
}

/// Discover sessions for a pre-discovered set of projects.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn discover_sessions_for(
    projects: &[DiscoveredProject],
    include_all: bool,
) -> Result<Vec<ResolvedSession>, CliError> {
    let mut sessions = Vec::new();
    for project in projects {
        for session_id in list_session_ids(project, include_all)? {
            if let Some(state) = load_session_state(project, &session_id)? {
                sessions.push(ResolvedSession {
                    project: project.clone(),
                    state,
                });
            }
        }
    }
    Ok(sessions)
}

/// Find one session across all discovered projects.
///
/// # Errors
/// Returns `CliError` when the session is missing or ambiguous.
pub fn resolve_session(session_id: &str) -> Result<ResolvedSession, CliError> {
    let mut matches: Vec<_> = discover_sessions(true)?
        .into_iter()
        .filter(|session| session.state.session_id == session_id)
        .collect();

    match matches.len() {
        0 => Err(
            CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into(),
        ),
        1 => Ok(matches.swap_remove(0)),
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "session '{session_id}' exists in multiple projects"
        ))
        .into()),
    }
}

/// Load a session state from either the canonical session repository or the
/// direct state path when the original project directory is unavailable.
///
/// # Errors
/// Returns `CliError` on parse failures.
pub fn load_session_state(
    project: &DiscoveredProject,
    session_id: &str,
) -> Result<Option<SessionState>, CliError> {
    if let Some(project_dir) = project.project_dir.as_deref()
        && let Some(state) = storage::load_state(project_dir, session_id)?
    {
        return Ok(Some(state));
    }

    load_session_state_from_context_root(&project.context_root, session_id)
}

/// Load the session audit log from either the repository helper or the direct path.
///
/// # Errors
/// Returns `CliError` on parse failures.
pub fn load_log_entries(
    project: &DiscoveredProject,
    session_id: &str,
) -> Result<Vec<SessionLogEntry>, CliError> {
    if let Some(project_dir) = project.project_dir.as_deref() {
        let entries = storage::load_log_entries(project_dir, session_id)?;
        if !entries.is_empty() {
            return Ok(entries);
        }
    }
    read_json_lines(
        &session_log_path(&project.context_root, session_id),
        "session log",
    )
}

/// Load task checkpoints from either the repository helper or direct JSONL.
///
/// # Errors
/// Returns `CliError` on parse failures.
pub fn load_task_checkpoints(
    project: &DiscoveredProject,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    if let Some(project_dir) = project.project_dir.as_deref() {
        let checkpoints = storage::load_task_checkpoints(project_dir, session_id, task_id)?;
        if !checkpoints.is_empty() {
            return Ok(checkpoints);
        }
    }
    read_json_lines(
        &task_checkpoints_path(&project.context_root, session_id, task_id),
        "task checkpoints",
    )
}

/// Load normalized conversation events from a canonical harness agent log.
///
/// # Errors
/// Returns `CliError` when the transcript cannot be read.
pub fn load_conversation_events(
    project: &DiscoveredProject,
    runtime: &str,
    session_id: &str,
    agent_id: &str,
) -> Result<Vec<ConversationEvent>, CliError> {
    let Some(adapter) = runtime_for_name(runtime) else {
        return Ok(Vec::new());
    };
    let native_events =
        load_native_conversation_events(project, adapter, runtime, session_id, agent_id)?;
    if !native_events.is_empty() {
        return Ok(native_events);
    }
    load_ledger_conversation_events(project, runtime, session_id, agent_id)
}

/// Resolve an orchestration session ID from a runtime session key within one
/// discovered project context.
///
/// # Errors
/// Returns `CliError` when session state cannot be loaded or when the runtime
/// session key is ambiguous.
pub fn resolve_session_id_for_runtime_session(
    context_root: &Path,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<String>, CliError> {
    if list_session_ids_from_context_root(context_root)?
        .iter()
        .any(|session_id| session_id == runtime_session_id)
    {
        return Ok(Some(runtime_session_id.to_string()));
    }

    let mut matches = Vec::new();

    for session_id in list_active_session_ids_from_context_root(context_root)? {
        let Some(state) = load_session_state_from_context_root(context_root, &session_id)? else {
            continue;
        };
        let agent_found = state.agents.values().any(|agent| {
            agent.runtime == runtime_name
                && (agent.agent_session_id.as_deref() == Some(runtime_session_id)
                    || (agent.agent_session_id.is_none() && state.session_id == runtime_session_id))
        });
        if agent_found {
            matches.push(state.session_id);
        }
    }

    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.into_iter().next()),
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{runtime_session_id}' for runtime '{runtime_name}' maps to multiple orchestration sessions"
        ))
        .into()),
    }
}

pub(super) fn list_session_ids_from_context_root(
    context_root: &Path,
) -> Result<Vec<String>, CliError> {
    let root = context_root.join("orchestration").join("sessions");
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let mut session_ids = Vec::new();
    for entry in fs::read_dir(root)
        .map_err(|error| CliErrorKind::workflow_io(format!("read session root: {error}")))?
    {
        let Ok(entry) = entry else {
            continue;
        };
        if entry.file_type().ok().is_some_and(|kind| kind.is_dir()) {
            session_ids.push(entry.file_name().to_string_lossy().to_string());
        }
    }
    session_ids.sort_unstable();
    Ok(session_ids)
}

pub(super) fn list_active_session_ids_from_context_root(
    context_root: &Path,
) -> Result<Vec<String>, CliError> {
    let path = context_root.join("orchestration").join("active.json");
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let registry = read_json_typed::<storage::ActiveRegistry>(&path)?;
    Ok(registry.sessions.into_keys().collect())
}

fn load_session_state_from_context_root(
    context_root: &Path,
    session_id: &str,
) -> Result<Option<SessionState>, CliError> {
    let path = session_state_path(context_root, session_id);
    if !path.is_file() {
        return Ok(None);
    }
    read_json_typed(&path).map(Some)
}

fn load_native_conversation_events(
    project: &DiscoveredProject,
    adapter: &dyn AgentRuntime,
    runtime: &str,
    session_id: &str,
    agent_id: &str,
) -> Result<Vec<ConversationEvent>, CliError> {
    let path = agent_transcript_path(&project.context_root, runtime, session_id);
    if !path.is_file() {
        return Ok(Vec::new());
    }

    let mut events = Vec::new();
    for_each_nonempty_line(&path, "agent transcript", |line, line_number| {
        let Some(mut event) = adapter.parse_log_entry(line) else {
            return Ok(());
        };
        event.sequence = u64::try_from(line_number).unwrap_or(u64::MAX);
        event.agent = agent_id.to_string();
        event.session_id = session_id.to_string();
        events.push(event);
        Ok(())
    })?;
    Ok(events)
}

fn load_ledger_conversation_events(
    project: &DiscoveredProject,
    runtime: &str,
    session_id: &str,
    agent_id: &str,
) -> Result<Vec<ConversationEvent>, CliError> {
    let path = project
        .context_root
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    if !path.is_file() {
        return Ok(Vec::new());
    }

    let mut events = Vec::new();
    for_each_nonempty_line(&path, "agent ledger", |line, _line_number| {
        let Some(event) = (|| {
            let entry = serde_json::from_str::<LedgerEventLine>(line).ok()?;
            if entry.agent != runtime || entry.session_id != session_id {
                return None;
            }
            let payload = serde_json::to_string(&entry.payload).ok()?;
            let mut event = parse_canonical_conversation_line(&payload, runtime)?;
            if event.timestamp.is_none() {
                event.timestamp = Some(entry.recorded_at);
            }
            event.sequence = entry.sequence;
            event.agent = agent_id.to_string();
            event.session_id = session_id.to_string();
            Some(event)
        })() else {
            return Ok(());
        };
        events.push(event);
        Ok(())
    })?;
    Ok(events)
}

fn list_session_ids(
    project: &DiscoveredProject,
    include_all: bool,
) -> Result<Vec<String>, CliError> {
    if let Some(project_dir) = project.project_dir.as_deref() {
        let session_ids = if include_all {
            storage::list_known_session_ids(project_dir)
        } else {
            Ok(storage::load_active_registry_for(project_dir)
                .sessions
                .into_keys()
                .collect())
        }?;
        if !session_ids.is_empty()
            || project_context_dir(project_dir) == project.context_root
        {
            return Ok(session_ids);
        }
    }

    if include_all {
        return list_session_ids_from_context_root(&project.context_root);
    }
    list_active_session_ids_from_context_root(&project.context_root)
}
