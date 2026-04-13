use std::collections::BTreeMap;
use std::fmt;
use std::fs::{FileType, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::result::Result as StdResult;

use fs_err as fs;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, validate_safe_segment, write_json_pretty};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::workspace::{
    GitCheckoutIdentity, project_context_dir, resolve_git_checkout_identity, utc_now,
};

use super::types::{
    CURRENT_VERSION, SessionLogEntry, SessionMetrics, SessionState, SessionTransition,
    TaskCheckpoint,
};

fn orchestration_root(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir).join("orchestration")
}

fn sessions_root(project_dir: &Path) -> PathBuf {
    orchestration_root(project_dir).join("sessions")
}

fn validate_session_id(session_id: &str) -> Result<(), CliError> {
    validate_safe_segment(session_id)
}

pub(crate) fn session_dir(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    validate_session_id(session_id)?;
    Ok(sessions_root(project_dir).join(session_id))
}

fn state_path(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("state.json"))
}

fn log_path(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("log.jsonl"))
}

fn tasks_root(project_dir: &Path, session_id: &str) -> Result<PathBuf, CliError> {
    Ok(session_dir(project_dir, session_id)?.join("tasks"))
}

fn task_dir(project_dir: &Path, session_id: &str, task_id: &str) -> Result<PathBuf, CliError> {
    Ok(tasks_root(project_dir, session_id)?.join(task_id))
}

fn checkpoints_path(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
) -> Result<PathBuf, CliError> {
    Ok(task_dir(project_dir, session_id, task_id)?.join("checkpoints.jsonl"))
}

fn active_registry_path(project_dir: &Path) -> PathBuf {
    orchestration_root(project_dir).join("active.json")
}

fn lock_path(project_dir: &Path, name: &str) -> PathBuf {
    orchestration_root(project_dir)
        .join(".locks")
        .join(format!("{name}.lock"))
}

fn with_lock<T>(
    project_dir: &Path,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    with_exclusive_flock(
        &lock_path(project_dir, name),
        FlockErrorContext::new("session storage"),
        action,
    )
}

fn io_err(error: &dyn fmt::Display) -> CliError {
    CliErrorKind::workflow_io(format!("session storage: {error}")).into()
}

/// Build a `VersionedJsonRepository` for the session state file.
pub(crate) fn state_repository(
    project_dir: &Path,
    session_id: &str,
) -> Result<VersionedJsonRepository<SessionState>, CliError> {
    Ok(
        VersionedJsonRepository::new(state_path(project_dir, session_id)?, CURRENT_VERSION)
            .with_migrations(vec![
                Box::new(migrate_v1_to_v2),
                Box::new(migrate_v2_to_v3),
                Box::new(migrate_v3_to_v4),
                Box::new(migrate_v4_to_v5),
                Box::new(migrate_v5_to_v6),
            ]),
    )
}

/// Load session state, returning `None` if the state file does not exist.
///
/// # Errors
/// Returns `CliError` on I/O or parse failures.
pub(crate) fn load_state(
    project_dir: &Path,
    session_id: &str,
) -> Result<Option<SessionState>, CliError> {
    state_repository(project_dir, session_id)?.load()
}

/// Save session state only when the session does not already exist.
///
/// # Errors
/// Returns `CliError` on I/O or serialization failures.
pub(crate) fn create_state(
    project_dir: &Path,
    session_id: &str,
    state: &SessionState,
) -> Result<bool, CliError> {
    let repository = state_repository(project_dir, session_id)?;
    let mut created = false;
    let _ = repository.update(|current| {
        if current.is_some() {
            return Ok(current);
        }
        created = true;
        Ok(Some(state.clone()))
    })?;
    Ok(created)
}

/// Load, modify, and save session state under an exclusive lock.
///
/// # Errors
/// Returns `CliError` on I/O, parse, or serialization failures, or if state is missing.
pub(crate) fn update_state<F>(
    project_dir: &Path,
    session_id: &str,
    update: F,
) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<(), CliError>,
{
    state_repository(project_dir, session_id)?
        .update(|state| {
            let Some(mut state) = state else {
                return Err(CliErrorKind::session_not_active(format!(
                    "session '{session_id}' not found"
                ))
                .into());
            };
            state.state_version += 1;
            state.updated_at = utc_now();
            update(&mut state)?;
            Ok(Some(state))
        })
        .and_then(|result| {
            result.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
            })
        })
}

/// Load, modify, and save session state only when the closure reports a
/// meaningful change.
///
/// The closure returns `true` when the state should be persisted. No-op updates
/// return the current state without rewriting the file.
///
/// # Errors
/// Returns `CliError` on I/O, parse, or serialization failures, or if state is missing.
pub(crate) fn update_state_if_changed<F>(
    project_dir: &Path,
    session_id: &str,
    update: F,
) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<bool, CliError>,
{
    state_repository(project_dir, session_id)?
        .update(|state| {
            let Some(mut state) = state else {
                return Err(CliErrorKind::session_not_active(format!(
                    "session '{session_id}' not found"
                ))
                .into());
            };
            let changed = update(&mut state)?;
            if changed {
                state.state_version += 1;
                state.updated_at = utc_now();
            }
            Ok(Some(state))
        })
        .and_then(|result| {
            result.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
            })
        })
}

/// Append a transition entry to the session's audit log.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn append_log_entry(
    project_dir: &Path,
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    validate_session_id(session_id)?;
    with_lock(project_dir, &format!("log-{session_id}"), || {
        let path = log_path(project_dir, session_id)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
        }
        let sequence = next_log_sequence(&path);
        let entry = SessionLogEntry {
            sequence,
            recorded_at: utc_now(),
            session_id: session_id.to_string(),
            transition,
            actor_id: actor_id.map(ToString::to_string),
            reason: reason.map(ToString::to_string),
        };
        append_json_line(&path, &entry)
    })
}

/// Load the append-only session audit log.
///
/// # Errors
/// Returns `CliError` on parse or I/O failure.
#[allow(dead_code)]
pub(crate) fn load_log_entries(
    project_dir: &Path,
    session_id: &str,
) -> Result<Vec<SessionLogEntry>, CliError> {
    read_json_lines(&log_path(project_dir, session_id)?, "session log")
}

/// Append a checkpoint entry for a task.
///
/// # Errors
/// Returns `CliError` on I/O or serialization failures.
pub(crate) fn append_task_checkpoint(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
    checkpoint: &TaskCheckpoint,
) -> Result<(), CliError> {
    with_lock(
        project_dir,
        &format!("checkpoint-{session_id}-{task_id}"),
        || {
            let path = checkpoints_path(project_dir, session_id, task_id)?;
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(|error| io_err(&error))?;
            }
            append_json_line(&path, checkpoint)
        },
    )
}

/// Load checkpoints for a single task.
///
/// # Errors
/// Returns `CliError` on parse or I/O failure.
#[allow(dead_code)]
pub(crate) fn load_task_checkpoints(
    project_dir: &Path,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    read_json_lines(
        &checkpoints_path(project_dir, session_id, task_id)?,
        "task checkpoints",
    )
}

/// List all known session IDs in a project, active or archived.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn list_known_session_ids(project_dir: &Path) -> Result<Vec<String>, CliError> {
    let root = sessions_root(project_dir);
    if !root.is_dir() {
        return Ok(Vec::new());
    }

    let mut session_ids: Vec<String> = fs::read_dir(root)
        .map_err(|error| io_err(&error))?
        .filter_map(StdResult::ok)
        .filter_map(|entry| {
            entry
                .file_type()
                .ok()
                .filter(FileType::is_dir)
                .and_then(|_| entry.file_name().into_string().ok())
        })
        .collect();
    session_ids.sort_unstable();
    Ok(session_ids)
}

fn next_log_sequence(path: &Path) -> u64 {
    let Ok(content) = fs::read_to_string(path) else {
        return 1;
    };
    let count = content
        .lines()
        .filter(|line| !line.trim().is_empty())
        .count();
    (count as u64) + 1
}

fn append_json_line<T: Serialize>(path: &Path, value: &T) -> Result<(), CliError> {
    let line = serde_json::to_string(value)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("session log: {error}")))?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| io_err(&error))?;
    writeln!(file, "{line}").map_err(|error| io_err(&error))?;
    Ok(())
}

#[allow(dead_code)]
fn read_json_lines<T>(path: &Path, label: &str) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
{
    if !path.is_file() {
        return Ok(Vec::new());
    }

    fs::read_to_string(path)
        .map_err(|error| io_err(&error))?
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line)
                .map_err(|error| CliErrorKind::workflow_parse(format!("{label}: {error}")).into())
        })
        .collect()
}

fn migrate_v1_to_v2(mut value: Value) -> Result<Value, CliError> {
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

fn migrate_v2_to_v3(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(3));
    object
        .entry("pending_leader_transfer".to_string())
        .or_insert(Value::Null);

    Ok(value)
}

fn migrate_v3_to_v4(mut value: Value) -> Result<Value, CliError> {
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

fn migrate_v4_to_v5(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    object.insert("schema_version".to_string(), json!(5));
    Ok(value)
}

fn migrate_v5_to_v6(mut value: Value) -> Result<Value, CliError> {
    let Some(object) = value.as_object_mut() else {
        return Err(CliErrorKind::workflow_version("session state is not a JSON object").into());
    };

    // Stamp schema version. The `Idle` agent status variant and `idle_agent_count`
    // metric are additive and will deserialize correctly from existing data since
    // no v5 state contains the `idle` status string.
    object.insert("schema_version".to_string(), json!(6));
    Ok(value)
}

/// Active session registry: maps session IDs to creation timestamps.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct ActiveRegistry {
    #[serde(default)]
    pub(crate) sessions: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ProjectOriginRecord {
    pub(crate) recorded_from_dir: String,
    pub(crate) repository_root: Option<String>,
    pub(crate) checkout_root: Option<String>,
    #[serde(default)]
    pub(crate) is_worktree: bool,
    pub(crate) worktree_name: Option<String>,
    pub(crate) recorded_at: String,
}

/// Register a session ID in the active registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn register_active(project_dir: &Path, session_id: &str) -> Result<(), CliError> {
    validate_session_id(session_id)?;
    with_lock(project_dir, "active-registry", || {
        let path = active_registry_path(project_dir);
        let mut registry = load_active_registry(&path);
        registry.sessions.insert(session_id.to_string(), utc_now());
        write_json_pretty(&path, &registry)
    })
}

/// Remove a session ID from the active registry.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn deregister_active(project_dir: &Path, session_id: &str) -> Result<(), CliError> {
    validate_session_id(session_id)?;
    with_lock(project_dir, "active-registry", || {
        let path = active_registry_path(project_dir);
        let mut registry = load_active_registry(&path);
        registry.sessions.remove(session_id);
        write_json_pretty(&path, &registry)
    })
}

/// Load the active session registry.
pub(crate) fn load_active_registry_for(project_dir: &Path) -> ActiveRegistry {
    load_active_registry(&active_registry_path(project_dir))
}

fn load_active_registry(path: &Path) -> ActiveRegistry {
    read_json_typed::<ActiveRegistry>(path).unwrap_or_default()
}

/// Filename for recording the originating project directory.
const PROJECT_ORIGIN_FILE: &str = "project-origin.json";

/// Record the originating project directory in the context root so
/// cross-project discovery can recover it later.
///
/// # Errors
/// Returns `CliError` on I/O failures.
pub(crate) fn record_project_origin(project_dir: &Path) -> Result<(), CliError> {
    let context_root = project_context_dir(project_dir);
    let path = context_root.join(PROJECT_ORIGIN_FILE);
    let identity = resolve_git_checkout_identity(project_dir);
    let previous = load_project_origin(&context_root);
    let origin = ProjectOriginRecord {
        recorded_from_dir: project_dir.to_string_lossy().to_string(),
        repository_root: identity
            .as_ref()
            .map(|value| value.repository_root.display().to_string()),
        checkout_root: identity
            .as_ref()
            .map(|value| value.checkout_root.display().to_string()),
        is_worktree: identity
            .as_ref()
            .is_some_and(GitCheckoutIdentity::is_worktree),
        worktree_name: identity.and_then(|value| value.worktree_name().map(ToString::to_string)),
        recorded_at: utc_now(),
    };
    let origin = merge_project_origin(origin, previous.as_ref());
    write_json_pretty(&path, &origin)
}

/// Load the recorded project origin for a context root.
#[must_use]
pub(crate) fn load_project_origin(context_root: &Path) -> Option<ProjectOriginRecord> {
    let path = context_root.join(PROJECT_ORIGIN_FILE);
    read_json_typed::<ProjectOriginRecord>(&path).ok()
}

fn merge_project_origin(
    mut origin: ProjectOriginRecord,
    previous: Option<&ProjectOriginRecord>,
) -> ProjectOriginRecord {
    let Some(previous) = previous else {
        return origin;
    };

    if origin.repository_root.is_none() {
        origin.repository_root.clone_from(&previous.repository_root);
    }
    if origin.checkout_root.is_none() {
        origin.checkout_root.clone_from(&previous.checkout_root);
    }
    if !origin.is_worktree && previous.is_worktree {
        origin.is_worktree = true;
        origin.worktree_name.clone_from(&previous.worktree_name);
    }
    if origin.worktree_name.is_none() {
        origin.worktree_name.clone_from(&previous.worktree_name);
    }
    origin
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::types::{
        AgentStatus, SessionRole, SessionStatus, TaskQueuePolicy, TaskSource, WorkItem,
    };

    fn sample_state(session_id: &str) -> SessionState {
        SessionState {
            schema_version: CURRENT_VERSION,
            state_version: 0,
            session_id: session_id.to_string(),
            title: "test title".into(),
            context: "test".into(),
            status: SessionStatus::Active,
            created_at: "2026-01-01T00:00:00Z".into(),
            updated_at: "2026-01-01T00:00:00Z".into(),
            agents: BTreeMap::from([(
                "claude-leader".into(),
                super::super::types::AgentRegistration {
                    agent_id: "claude-leader".into(),
                    name: "claude leader".into(),
                    runtime: "claude".into(),
                    role: SessionRole::Leader,
                    capabilities: Vec::new(),
                    joined_at: "2026-01-01T00:00:00Z".into(),
                    updated_at: "2026-01-01T00:00:00Z".into(),
                    status: AgentStatus::Active,
                    agent_session_id: None,
                    last_activity_at: Some("2026-01-01T00:00:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: RuntimeCapabilities::default(),
                    persona: None,
                },
            )]),
            tasks: BTreeMap::from([(
                "task-1".into(),
                WorkItem {
                    task_id: "task-1".into(),
                    title: "task".into(),
                    context: None,
                    severity: super::super::types::TaskSeverity::Medium,
                    status: super::super::types::TaskStatus::Open,
                    assigned_to: None,
                    queue_policy: TaskQueuePolicy::Locked,
                    queued_at: None,
                    created_at: "2026-01-01T00:00:00Z".into(),
                    updated_at: "2026-01-01T00:00:00Z".into(),
                    created_by: None,
                    notes: Vec::new(),
                    suggested_fix: None,
                    source: TaskSource::Manual,
                    blocked_reason: None,
                    completed_at: None,
                    checkpoint_summary: None,
                },
            )]),
            leader_id: Some("claude-leader".into()),
            archived_at: None,
            last_activity_at: Some("2026-01-01T00:00:00Z".into()),
            observe_id: Some(format!("observe-{session_id}")),
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        }
    }

    #[test]
    fn state_round_trip_via_repository() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("CLAUDE_SESSION_ID", Some("test-storage")),
            ],
            || {
                let project = tmp.path().join("project");
                let state = sample_state("sess-1");
                assert!(create_state(&project, "sess-1", &state).expect("create"));
                let loaded = load_state(&project, "sess-1")
                    .expect("load")
                    .expect("state");
                assert_eq!(loaded.session_id, "sess-1");
                assert_eq!(loaded.observe_id.as_deref(), Some("observe-sess-1"));
            },
        );
    }

    #[test]
    fn migrate_v1_and_v2_stamp_expected_schema_versions() {
        let v1 = json!({
            "schema_version": 1,
            "session_id": "sess-1",
            "context": "test",
            "status": "active",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "agents": {},
            "tasks": {},
        });
        let migrated_v2 = migrate_v1_to_v2(v1).expect("migrate v1");
        assert_eq!(migrated_v2["schema_version"], json!(2));

        let v2 = json!({
            "schema_version": 2,
            "session_id": "sess-1",
            "context": "test",
            "status": "active",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "agents": {},
            "tasks": {},
        });
        let migrated_v3 = migrate_v2_to_v3(v2).expect("migrate v2");
        assert_eq!(migrated_v3["schema_version"], json!(3));
    }

    #[test]
    fn migrate_v3_to_v4_backfills_title_from_context() {
        let migrated = migrate_v3_to_v4(json!({
            "schema_version": 3,
            "state_version": 2,
            "session_id": "sess-1",
            "context": "session goal",
            "status": "active",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "agents": {},
            "tasks": {},
            "leader_id": null,
            "archived_at": null,
            "last_activity_at": null,
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {
                "agent_count": 0,
                "active_agent_count": 0,
                "open_task_count": 0,
                "in_progress_task_count": 0,
                "blocked_task_count": 0,
                "completed_task_count": 0
            }
        }))
        .expect("migrate v3");

        assert_eq!(migrated["schema_version"], json!(4));
        assert_eq!(migrated["title"], json!("session goal"));
    }

    #[test]
    fn migrate_v4_to_v5_stamps_current_schema() {
        let migrated = migrate_v4_to_v5(json!({
            "schema_version": 4,
            "state_version": 2,
            "session_id": "sess-1",
            "title": "session title",
            "context": "session goal",
            "status": "active",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "agents": {},
            "tasks": {},
            "leader_id": null,
            "archived_at": null,
            "last_activity_at": null,
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {
                "agent_count": 0,
                "active_agent_count": 0,
                "open_task_count": 0,
                "in_progress_task_count": 0,
                "blocked_task_count": 0,
                "completed_task_count": 0
            }
        }))
        .expect("migrate v4");

        assert_eq!(migrated["schema_version"], json!(5));
        assert_eq!(migrated["title"], json!("session title"));
    }

    #[test]
    fn migrate_v5_to_v6_stamps_current_schema() {
        let migrated = migrate_v5_to_v6(json!({
            "schema_version": 5,
            "state_version": 3,
            "session_id": "sess-1",
            "title": "session title",
            "context": "session goal",
            "status": "active",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "agents": {},
            "tasks": {},
            "leader_id": null,
            "archived_at": null,
            "last_activity_at": null,
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {
                "agent_count": 0,
                "active_agent_count": 0,
                "open_task_count": 0,
                "in_progress_task_count": 0,
                "blocked_task_count": 0,
                "completed_task_count": 0
            }
        }))
        .expect("migrate v5");

        assert_eq!(migrated["schema_version"], json!(CURRENT_VERSION));
        assert_eq!(migrated["title"], json!("session title"));
    }

    #[test]
    fn merge_project_origin_preserves_existing_git_identity() {
        let merged = merge_project_origin(
            ProjectOriginRecord {
                recorded_from_dir: "/repo/.claude/worktrees/feature".to_string(),
                repository_root: None,
                checkout_root: None,
                is_worktree: false,
                worktree_name: None,
                recorded_at: "2026-04-10T10:00:00Z".to_string(),
            },
            Some(&ProjectOriginRecord {
                recorded_from_dir: "/repo/.claude/worktrees/feature".to_string(),
                repository_root: Some("/repo".to_string()),
                checkout_root: Some("/repo/.claude/worktrees/feature".to_string()),
                is_worktree: true,
                worktree_name: Some("feature".to_string()),
                recorded_at: "2026-04-10T09:00:00Z".to_string(),
            }),
        );

        assert_eq!(merged.repository_root.as_deref(), Some("/repo"));
        assert_eq!(
            merged.checkout_root.as_deref(),
            Some("/repo/.claude/worktrees/feature")
        );
        assert!(merged.is_worktree);
        assert_eq!(merged.worktree_name.as_deref(), Some("feature"));
    }

    #[test]
    fn load_state_migrates_v3_state_and_persists_current_schema() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("CLAUDE_SESSION_ID", Some("test-session-migration")),
            ],
            || {
                let project = tmp.path().join("project");
                let session_id = "sess-legacy";
                let state_file = state_path(&project, session_id).expect("state path");
                if let Some(parent) = state_file.parent() {
                    fs::create_dir_all(parent).expect("create session dir");
                }
                write_json_pretty(
                    &state_file,
                    &json!({
                        "schema_version": 3,
                        "state_version": 7,
                        "session_id": session_id,
                        "context": "legacy context",
                        "status": "active",
                        "created_at": "2026-01-01T00:00:00Z",
                        "updated_at": "2026-01-01T00:00:00Z",
                        "agents": {},
                        "tasks": {},
                        "leader_id": null,
                        "archived_at": null,
                        "last_activity_at": null,
                        "observe_id": null,
                        "pending_leader_transfer": null,
                        "metrics": {
                            "agent_count": 0,
                            "active_agent_count": 0,
                            "open_task_count": 0,
                            "in_progress_task_count": 0,
                            "blocked_task_count": 0,
                            "completed_task_count": 0
                        }
                    }),
                )
                .expect("write legacy state");

                let loaded = load_state(&project, session_id)
                    .expect("load state")
                    .expect("state present");
                assert_eq!(loaded.schema_version, CURRENT_VERSION);
                assert_eq!(loaded.title, "legacy context");

                let persisted: Value = read_json_typed(&state_file).expect("read migrated state");
                assert_eq!(persisted["schema_version"], json!(CURRENT_VERSION));
                assert_eq!(persisted["title"], json!("legacy context"));
            },
        );
    }

    #[test]
    fn append_and_load_log_entries() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("CLAUDE_SESSION_ID", Some("test-log")),
            ],
            || {
                let project = tmp.path().join("project");
                append_log_entry(
                    &project,
                    "sess-1",
                    SessionTransition::SessionStarted {
                        title: "test title".into(),
                        context: "test".into(),
                    },
                    Some("leader"),
                    None,
                )
                .expect("append started");
                append_log_entry(
                    &project,
                    "sess-1",
                    SessionTransition::SessionEnded,
                    Some("leader"),
                    None,
                )
                .expect("append ended");

                let entries = load_log_entries(&project, "sess-1").expect("load log");
                assert_eq!(entries.len(), 2);
                assert_eq!(entries[1].sequence, 2);
            },
        );
    }

    #[test]
    fn create_state_rejects_unsafe_session_id() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("CLAUDE_SESSION_ID", Some("test-unsafe-session-id")),
            ],
            || {
                let project = tmp.path().join("project");
                let escape_dir = tmp.path().join("escape");
                let unsafe_id = escape_dir.to_string_lossy().into_owned();
                let state = sample_state(&unsafe_id);

                let error = create_state(&project, &unsafe_id, &state).expect_err("unsafe id");

                assert_eq!(error.code(), "KSRCLI059");
                assert!(!escape_dir.join("state.json").exists());
            },
        );
    }

    #[test]
    fn checkpoint_round_trip_is_append_only() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("CLAUDE_SESSION_ID", Some("test-checkpoints")),
            ],
            || {
                let project = tmp.path().join("project");
                let checkpoint = TaskCheckpoint {
                    checkpoint_id: "task-1-cp-1".into(),
                    task_id: "task-1".into(),
                    recorded_at: "2026-03-28T12:00:00Z".into(),
                    actor_id: Some("claude-leader".into()),
                    summary: "watch attached".into(),
                    progress: 40,
                };
                append_task_checkpoint(&project, "sess-1", "task-1", &checkpoint)
                    .expect("append checkpoint");
                let checkpoints =
                    load_task_checkpoints(&project, "sess-1", "task-1").expect("load");
                assert_eq!(checkpoints.len(), 1);
                assert_eq!(checkpoints[0].progress, 40);
            },
        );
    }

    #[test]
    fn active_registry_round_trip() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("CLAUDE_SESSION_ID", Some("test-registry")),
            ],
            || {
                let project = tmp.path().join("project");
                register_active(&project, "sess-a").expect("register a");
                register_active(&project, "sess-b").expect("register b");
                let registry = load_active_registry_for(&project);
                assert_eq!(registry.sessions.len(), 2);
                deregister_active(&project, "sess-a").expect("remove a");
                let registry = load_active_registry_for(&project);
                assert_eq!(registry.sessions.len(), 1);
                assert!(registry.sessions.contains_key("sess-b"));
            },
        );
    }
}
