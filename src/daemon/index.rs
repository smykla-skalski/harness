use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::session::storage;
use crate::session::types::{SessionLogEntry, SessionState, TaskCheckpoint};
use crate::workspace::harness_data_root;

#[derive(Debug, Clone)]
pub struct DiscoveredProject {
    pub project_id: String,
    pub name: String,
    pub project_dir: Option<PathBuf>,
    pub context_root: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ResolvedSession {
    pub project: DiscoveredProject,
    pub state: SessionState,
}

#[must_use]
pub fn projects_root() -> PathBuf {
    harness_data_root().join("projects")
}

/// Discover harness project context roots on disk.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn discover_projects() -> Result<Vec<DiscoveredProject>, CliError> {
    let root = projects_root();
    if !root.is_dir() {
        return Ok(Vec::new());
    }

    let mut projects = Vec::new();
    for entry in fs::read_dir(root)
        .map_err(|error| CliErrorKind::workflow_io(format!("read daemon projects root: {error}")))?
    {
        let Ok(entry) = entry else {
            continue;
        };
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_dir() {
            continue;
        }

        let context_root = entry.path();
        let project_id = entry.file_name().to_string_lossy().to_string();
        let project_dir = infer_project_dir(&context_root);
        let name = project_dir
            .as_ref()
            .and_then(|path| path.file_name())
            .map_or_else(
                || project_id.clone(),
                |name| name.to_string_lossy().to_string(),
            );

        projects.push(DiscoveredProject {
            project_id,
            name,
            project_dir,
            context_root,
        });
    }

    projects.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(projects)
}

/// Discover every session reachable from all harness project contexts.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn discover_sessions(include_all: bool) -> Result<Vec<ResolvedSession>, CliError> {
    let mut sessions = Vec::new();
    for project in discover_projects()? {
        for session_id in list_session_ids(&project, include_all)? {
            if let Some(state) = load_session_state(&project, &session_id)? {
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
    if let Some(project_dir) = project.project_dir.as_deref() {
        return storage::load_state(project_dir, session_id);
    }

    let path = session_state_path(&project.context_root, session_id);
    if !path.is_file() {
        return Ok(None);
    }
    read_json_typed(&path).map(Some)
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
        return storage::load_log_entries(project_dir, session_id);
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
        return storage::load_task_checkpoints(project_dir, session_id, task_id);
    }
    read_json_lines(
        &task_checkpoints_path(&project.context_root, session_id, task_id),
        "task checkpoints",
    )
}

#[must_use]
pub fn signals_root(context_root: &Path) -> PathBuf {
    context_root.join("agents").join("signals")
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

    let project = DiscoveredProject {
        project_id: context_root
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().to_string()),
        name: context_root
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().to_string()),
        project_dir: infer_project_dir(context_root),
        context_root: context_root.to_path_buf(),
    };
    let mut matches = Vec::new();

    for session_id in list_active_session_ids_from_context_root(context_root)? {
        let Some(state) = load_session_state(&project, &session_id)? else {
            continue;
        };
        let matched = state.agents.values().any(|agent| {
            agent.runtime == runtime_name
                && (agent.agent_session_id.as_deref() == Some(runtime_session_id)
                    || (agent.agent_session_id.is_none() && state.session_id == runtime_session_id))
        });
        if matched {
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

#[must_use]
pub fn observe_snapshot_path(context_root: &Path, observe_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("observe")
        .join(observe_id)
        .join("snapshot.json")
}

fn infer_project_dir(context_root: &Path) -> Option<PathBuf> {
    let ledger_path = context_root
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    let content = fs::read_to_string(ledger_path).ok()?;
    content
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .and_then(|line| serde_json::from_str::<Value>(line).ok())
        .and_then(|entry| entry.get("cwd").and_then(Value::as_str).map(PathBuf::from))
}

fn list_session_ids(
    project: &DiscoveredProject,
    include_all: bool,
) -> Result<Vec<String>, CliError> {
    if let Some(project_dir) = project.project_dir.as_deref() {
        return if include_all {
            storage::list_known_session_ids(project_dir)
        } else {
            Ok(storage::load_active_registry_for(project_dir)
                .sessions
                .into_keys()
                .collect())
        };
    }

    if include_all {
        return list_session_ids_from_context_root(&project.context_root);
    }
    list_active_session_ids_from_context_root(&project.context_root)
}

fn list_session_ids_from_context_root(context_root: &Path) -> Result<Vec<String>, CliError> {
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

fn list_active_session_ids_from_context_root(context_root: &Path) -> Result<Vec<String>, CliError> {
    let path = context_root.join("orchestration").join("active.json");
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let registry = read_json_typed::<storage::ActiveRegistry>(&path)?;
    Ok(registry.sessions.into_keys().collect())
}

fn session_state_path(context_root: &Path, session_id: &str) -> PathBuf {
    context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("state.json")
}

fn session_log_path(context_root: &Path, session_id: &str) -> PathBuf {
    context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("log.jsonl")
}

fn task_checkpoints_path(context_root: &Path, session_id: &str, task_id: &str) -> PathBuf {
    context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("tasks")
        .join(task_id)
        .join("checkpoints.jsonl")
}

fn read_json_lines<T>(path: &Path, label: &str) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
{
    if !path.is_file() {
        return Ok(Vec::new());
    }
    fs::read_to_string(path)
        .map_err(|error| CliErrorKind::workflow_io(format!("read {label}: {error}")))?
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line)
                .map_err(|error| CliErrorKind::workflow_parse(format!("{label}: {error}")).into())
        })
        .collect()
}
