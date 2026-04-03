use std::collections::BTreeSet;
use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use crate::agents::runtime::{
    AgentRuntime, event::ConversationEvent, parse_canonical_conversation_line, runtime_for_name,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::session::storage;
use crate::session::types::{SessionLogEntry, SessionState, TaskCheckpoint};
use crate::workspace::{harness_data_root, project_context_dir, resolve_git_checkout_identity};
use fs_err as fs;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

#[derive(Debug, Deserialize)]
struct LedgerEventLine {
    sequence: u64,
    recorded_at: String,
    agent: String,
    session_id: String,
    payload: Value,
}

#[derive(Debug, Clone)]
pub struct DiscoveredProject {
    pub project_id: String,
    pub name: String,
    pub project_dir: Option<PathBuf>,
    pub repository_root: Option<PathBuf>,
    pub checkout_id: String,
    pub checkout_name: String,
    pub context_root: PathBuf,
    pub is_worktree: bool,
    pub worktree_name: Option<String>,
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

/// Fast counts for the health endpoint. Reads directory entries only - no git
/// operations, no JSON parsing, no state loading.
#[must_use]
pub fn fast_counts() -> (usize, usize, usize) {
    let root = projects_root();
    if !root.is_dir() {
        return (0, 0, 0);
    }
    let Ok(entries) = fs::read_dir(&root) else {
        return (0, 0, 0);
    };
    let context_roots: Vec<_> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    let project_count = context_roots.len();
    let mut session_count = 0;
    let mut worktree_count = 0;
    for context_root in &context_roots {
        let sessions_dir = context_root.join("orchestration").join("sessions");
        if let Ok(sessions) = fs::read_dir(sessions_dir) {
            session_count += sessions
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
                .count();
        }
        let origin_path = context_root.join("project-origin.json");
        if let Ok(data) = fs::read_to_string(&origin_path)
            && (data.contains("\"is_worktree\":true") || data.contains("\"is_worktree\": true"))
        {
            worktree_count += 1;
        }
    }
    (project_count, worktree_count, session_count)
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

    let raw_context_roots: Vec<_> = fs::read_dir(&root)
        .map_err(|error| CliErrorKind::workflow_io(format!("read daemon projects root: {error}")))?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();

    let mut projects = Vec::new();
    let mut seen_context_roots = BTreeSet::new();
    for raw_context_root in raw_context_roots {
        let Some(context_root) = repair_context_root(&raw_context_root)? else {
            continue;
        };
        if !seen_context_roots.insert(context_root.clone()) {
            continue;
        }
        let project = build_discovered_project(&context_root)
            .unwrap_or_else(|| fallback_project(&context_root));
        projects.push(project);
    }

    projects.sort_by(|left, right| {
        left.name
            .cmp(&right.name)
            .then(left.checkout_name.cmp(&right.checkout_name))
    });
    Ok(projects)
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

    let content = fs::read_to_string(&path).map_err(|error| {
        CliErrorKind::workflow_io(format!("read agent transcript {}: {error}", path.display()))
    })?;
    Ok(content
        .lines()
        .enumerate()
        .filter_map(|(index, line)| {
            let mut event = adapter.parse_log_entry(line)?;
            event.sequence = u64::try_from(index.saturating_add(1)).unwrap_or(u64::MAX);
            event.agent = agent_id.to_string();
            event.session_id = session_id.to_string();
            Some(event)
        })
        .collect())
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

    Ok(fs::read_to_string(&path)
        .map_err(|error| CliErrorKind::workflow_io(format!("read agent ledger: {error}")))?
        .lines()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| {
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
        })
        .collect())
}

#[must_use]
pub fn signals_root(context_root: &Path) -> PathBuf {
    context_root.join("agents").join("signals")
}

#[must_use]
pub fn agent_transcript_path(context_root: &Path, runtime: &str, session_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("sessions")
        .join(runtime)
        .join(session_id)
        .join("raw.jsonl")
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
        project_dir: infer_checkout_identity(context_root).map(|identity| identity.checkout_root),
        repository_root: None,
        checkout_id: context_root
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().to_string()),
        checkout_name: "Repository".to_string(),
        context_root: context_root.to_path_buf(),
        is_worktree: false,
        worktree_name: None,
    };
    let mut matches = Vec::new();

    for session_id in list_active_session_ids_from_context_root(context_root)? {
        let Some(state) = load_session_state(&project, &session_id)? else {
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

#[must_use]
pub fn observe_snapshot_path(context_root: &Path, observe_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("observe")
        .join(observe_id)
        .join("snapshot.json")
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
        if !session_ids.is_empty() || project_context_dir(project_dir) == project.context_root {
            return Ok(session_ids);
        }
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

#[derive(Debug, Clone)]
struct InferredCheckout {
    repository_root: PathBuf,
    checkout_root: PathBuf,
    is_worktree: bool,
    worktree_name: Option<String>,
}

fn fallback_project(context_root: &Path) -> DiscoveredProject {
    let project_id = project_context_dir_name(context_root).unwrap_or_default();
    let name = context_root
        .file_name()
        .map_or_else(|| project_id.clone(), |name| name.to_string_lossy().to_string());
    DiscoveredProject {
        project_id: project_id.clone(),
        name,
        project_dir: None,
        repository_root: None,
        checkout_id: project_id,
        checkout_name: "Unknown".to_string(),
        context_root: context_root.to_path_buf(),
        is_worktree: false,
        worktree_name: None,
    }
}

fn build_discovered_project(context_root: &Path) -> Option<DiscoveredProject> {
    let identity = infer_checkout_identity(context_root)?;
    let project_id = project_context_dir_name(&project_context_dir(&identity.repository_root))
        .unwrap_or_default();
    let name = identity.repository_root.file_name().map_or_else(
        || project_id.clone(),
        |name| name.to_string_lossy().to_string(),
    );
    let checkout_name = if identity.is_worktree {
        identity.worktree_name.clone().unwrap_or_else(|| {
            identity
                .checkout_root
                .file_name()
                .map_or_else(String::new, |name| name.to_string_lossy().to_string())
        })
    } else {
        "Repository".to_string()
    };

    Some(DiscoveredProject {
        project_id,
        name,
        project_dir: Some(identity.checkout_root),
        repository_root: Some(identity.repository_root),
        checkout_id: project_context_dir_name(context_root).unwrap_or_default(),
        checkout_name,
        context_root: context_root.to_path_buf(),
        is_worktree: identity.is_worktree,
        worktree_name: identity.worktree_name,
    })
}

fn repair_context_root(context_root: &Path) -> Result<Option<PathBuf>, CliError> {
    if !context_root.is_dir() {
        return Ok(None);
    }

    let Some(identity) = infer_checkout_identity(context_root) else {
        if context_has_sessions(context_root)? {
            return Ok(Some(context_root.to_path_buf()));
        }
        prune_context_root(context_root, "pruned non-git project context")?;
        return Ok(None);
    };
    let canonical_context_root = project_context_dir(&identity.checkout_root);
    if canonical_context_root != context_root {
        reconcile_legacy_context(context_root, &canonical_context_root)?;
    }

    if canonical_context_root.is_dir() {
        storage::record_project_origin(&identity.checkout_root)?;
        return Ok(Some(canonical_context_root));
    }
    Ok(None)
}

fn reconcile_legacy_context(
    context_root: &Path,
    canonical_context_root: &Path,
) -> Result<(), CliError> {
    if context_has_sessions(context_root)? {
        migrate_and_log_context(context_root, canonical_context_root)?;
    } else {
        prune_context_root(context_root, "pruned legacy project alias")?;
    }
    Ok(())
}

fn migrate_and_log_context(source: &Path, target: &Path) -> Result<(), CliError> {
    migrate_context_root(source, target)?;
    emit_info(&format!(
        "migrated legacy project context {} to {}",
        source.display(),
        target.display()
    ));
    Ok(())
}

fn infer_checkout_identity(context_root: &Path) -> Option<InferredCheckout> {
    if let Some(origin) = storage::load_project_origin(context_root)
        && let Some(checkout_root) = origin.checkout_root.as_deref().map(PathBuf::from)
    {
        if let Some(identity) = resolve_git_checkout_identity(&checkout_root) {
            let is_worktree = identity.is_worktree();
            let worktree_name = identity.worktree_name().map(ToString::to_string);
            return Some(InferredCheckout {
                repository_root: identity.repository_root,
                checkout_root: identity.checkout_root,
                is_worktree,
                worktree_name,
            });
        }
        let repository_root = origin
            .repository_root
            .as_deref()
            .map_or_else(|| checkout_root.clone(), PathBuf::from);
        return Some(InferredCheckout {
            repository_root,
            checkout_root,
            is_worktree: origin.is_worktree,
            worktree_name: origin.worktree_name,
        });
    }

    let cwd = infer_ledger_cwd(context_root)?;
    let identity = resolve_git_checkout_identity(&cwd)?;
    let is_worktree = identity.is_worktree();
    let worktree_name = identity.worktree_name().map(ToString::to_string);
    Some(InferredCheckout {
        repository_root: identity.repository_root,
        checkout_root: identity.checkout_root,
        is_worktree,
        worktree_name,
    })
}

fn infer_ledger_cwd(context_root: &Path) -> Option<PathBuf> {
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

fn context_has_sessions(context_root: &Path) -> Result<bool, CliError> {
    Ok(!list_session_ids_from_context_root(context_root)?.is_empty())
}

fn prune_context_root(context_root: &Path, reason: &str) -> Result<(), CliError> {
    if !context_root.exists() {
        return Ok(());
    }
    remove_context_dir(context_root)?;
    log_context_prune(context_root, reason);
    Ok(())
}

fn log_context_prune(context_root: &Path, reason: &str) {
    emit_info(&format!("{reason}: {}", context_root.display()));
}

/// Manual tracing event dispatch. The `info!` macro has inherent cognitive
/// complexity of 8 due to its internal expansion (tokio-rs/tracing#553),
/// which exceeds the pedantic threshold of 7.
fn emit_info(message: &str) {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "info",
        "harness::daemon::index",
        Level::INFO,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let values: &[Option<&dyn Value>] = &[Some(&message)];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}

fn remove_context_dir(context_root: &Path) -> Result<(), CliError> {
    fs::remove_dir_all(context_root).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "remove project context {}: {error}",
            context_root.display()
        ))
    })?;
    Ok(())
}

fn migrate_context_root(source: &Path, target: &Path) -> Result<(), CliError> {
    if source == target || !source.is_dir() {
        return Ok(());
    }
    if !target.exists() {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "create canonical project context parent {}: {error}",
                    parent.display()
                ))
            })?;
        }
        fs::rename(source, target).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "move project context {} -> {}: {error}",
                source.display(),
                target.display()
            ))
        })?;
        return Ok(());
    }

    merge_context_roots(source, target)?;
    fs::remove_dir_all(source).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "remove migrated project context {}: {error}",
            source.display()
        ))
    })?;
    Ok(())
}

fn merge_context_roots(source: &Path, target: &Path) -> Result<(), CliError> {
    merge_active_registries(source, target)?;
    merge_append_only_file(
        &source.join("agents").join("ledger").join("events.jsonl"),
        &target.join("agents").join("ledger").join("events.jsonl"),
    )?;

    let mut pending = vec![source.to_path_buf()];
    while let Some(current) = pending.pop() {
        merge_directory_entries(source, target, &current, &mut pending)?;
    }

    Ok(())
}

fn merge_directory_entries(
    source: &Path,
    target: &Path,
    current: &Path,
    pending: &mut Vec<PathBuf>,
) -> Result<(), CliError> {
    for entry in fs::read_dir(current).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read project context merge directory {}: {error}",
            current.display()
        ))
    })? {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        let Ok(relative) = path.strip_prefix(source) else {
            continue;
        };
        if skip_merged_path(relative) {
            continue;
        }
        let target_path = target.join(relative);
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            fs::create_dir_all(&target_path).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "create merged project directory {}: {error}",
                    target_path.display()
                ))
            })?;
            pending.push(path);
            continue;
        }
        if target_path.exists() {
            continue;
        }
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "create merged project file parent {}: {error}",
                    parent.display()
                ))
            })?;
        }
        fs::copy(&path, &target_path).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "copy merged project file {} -> {}: {error}",
                path.display(),
                target_path.display()
            ))
        })?;
    }
    Ok(())
}

fn merge_active_registries(source: &Path, target: &Path) -> Result<(), CliError> {
    let source_path = source.join("orchestration").join("active.json");
    if !source_path.is_file() {
        return Ok(());
    }

    let target_path = target.join("orchestration").join("active.json");
    let source_registry =
        read_json_typed::<storage::ActiveRegistry>(&source_path).unwrap_or_default();
    let mut target_registry =
        read_json_typed::<storage::ActiveRegistry>(&target_path).unwrap_or_default();
    for (session_id, timestamp) in source_registry.sessions {
        target_registry
            .sessions
            .entry(session_id)
            .and_modify(|current| {
                if timestamp > *current {
                    current.clone_from(&timestamp);
                }
            })
            .or_insert(timestamp);
    }
    if let Some(parent) = target_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "create active registry parent {}: {error}",
                parent.display()
            ))
        })?;
    }
    write_json_pretty(&target_path, &target_registry)
}

fn merge_append_only_file(source: &Path, target: &Path) -> Result<(), CliError> {
    if !source.is_file() {
        return Ok(());
    }
    let contents = fs::read_to_string(source).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read append-only file {}: {error}",
            source.display()
        ))
    })?;
    if contents.trim().is_empty() {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "create append-only file parent {}: {error}",
                parent.display()
            ))
        })?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(target)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "open append-only file {}: {error}",
                target.display()
            ))
        })?;
    file.write_all(contents.as_bytes()).map_err(|error| {
        CliErrorKind::workflow_io(format!("append file {}: {error}", target.display()))
    })?;
    if !contents.ends_with('\n') {
        writeln!(file).map_err(|error| {
            CliErrorKind::workflow_io(format!("terminate file {}: {error}", target.display()))
        })?;
    }
    Ok(())
}

fn skip_merged_path(relative: &Path) -> bool {
    if relative
        .components()
        .any(|component| component.as_os_str() == ".locks")
    {
        return true;
    }
    matches!(
        relative.to_string_lossy().as_ref(),
        "project-origin.json" | "orchestration/active.json" | "agents/ledger/events.jsonl"
    )
}

fn project_context_dir_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    use fs_err as fs;
    use tempfile::tempdir;

    fn write_text(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        fs::write(path, contents).expect("write file");
    }

    #[test]
    fn load_conversation_events_falls_back_to_ledger_for_copilot() {
        let tmp = tempdir().expect("tempdir");
        let context_root = tmp.path().join("context");
        let ledger_path = context_root.join("agents/ledger/events.jsonl");
        let make_payload = |timestamp: &str, block: serde_json::Value| {
            serde_json::json!({
                "timestamp": timestamp,
                "message": {
                    "role": "assistant",
                    "content": [block],
                }
            })
        };
        let entries = [
            serde_json::json!({
                "sequence": 1,
                "recorded_at": "2026-03-29T10:00:00Z",
                "agent": "copilot",
                "session_id": "copilot-session-1",
                "skill": "suite",
                "event": "before_tool_use",
                "hook": "tool-guard",
                "decision": "allow",
                "cwd": "/tmp/project",
                "payload": make_payload(
                    "2026-03-29T10:00:00Z",
                    serde_json::json!({
                        "type": "tool_use",
                        "name": "Read",
                        "input": {"path": "README.md"},
                        "id": "call-1",
                    }),
                ),
            }),
            serde_json::json!({
                "sequence": 2,
                "recorded_at": "2026-03-29T10:00:02Z",
                "agent": "copilot",
                "session_id": "copilot-session-1",
                "skill": "suite",
                "event": "after_tool_use",
                "hook": "tool-result",
                "decision": "allow",
                "cwd": "/tmp/project",
                "payload": make_payload(
                    "2026-03-29T10:00:02Z",
                    serde_json::json!({
                        "type": "tool_result",
                        "tool_name": "Read",
                        "tool_use_id": "call-1",
                        "content": {"line_count": 12},
                        "is_error": false,
                    }),
                ),
            }),
        ];
        let contents = entries
            .iter()
            .map(|entry| serde_json::to_string(entry).expect("serialize"))
            .collect::<Vec<_>>()
            .join("\n");
        write_text(&ledger_path, &contents);

        let project = DiscoveredProject {
            project_id: "project-alpha".into(),
            name: "project-alpha".into(),
            project_dir: None,
            repository_root: None,
            checkout_id: "project-alpha".into(),
            checkout_name: "Repository".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };

        let events =
            load_conversation_events(&project, "copilot", "copilot-session-1", "copilot-worker")
                .expect("events");

        assert_eq!(events.len(), 2);
        assert_eq!(events[0].sequence, 1);
        assert_eq!(events[0].agent, "copilot-worker");
        assert_eq!(events[0].session_id, "copilot-session-1");
        assert!(matches!(
            events[0].kind,
            crate::agents::runtime::event::ConversationEventKind::ToolInvocation {
                ref tool_name,
                ..
            } if tool_name == "Read"
        ));
        assert!(matches!(
            events[1].kind,
            crate::agents::runtime::event::ConversationEventKind::ToolResult {
                ref tool_name,
                ..
            } if tool_name == "Read"
        ));
    }
}
