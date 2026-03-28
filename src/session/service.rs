use std::collections::BTreeMap;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::roles::{SessionAction, is_permitted};
use super::storage;
use super::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, SessionRole, SessionState, SessionStatus,
    SessionTransition, TaskNote, TaskSeverity, TaskStatus, WorkItem,
};

/// Start a new orchestration session and register the caller as leader.
///
/// # Errors
/// Returns `CliError` on storage failures.
pub fn start_session(
    context: &str,
    project_dir: &Path,
    runtime: Option<&str>,
    session_id: Option<&str>,
) -> Result<SessionState, CliError> {
    let now = utc_now();
    let session_id = session_id
        .filter(|value| !value.trim().is_empty())
        .map_or_else(|| generate_session_id(&now), ToString::to_string);

    let runtime_name = runtime.unwrap_or("unknown");
    let leader_id = format!("{runtime_name}-leader");

    let mut agents = BTreeMap::new();
    agents.insert(
        leader_id.clone(),
        AgentRegistration {
            agent_id: leader_id.clone(),
            name: format!("{runtime_name} leader"),
            runtime: runtime_name.to_string(),
            role: SessionRole::Leader,
            capabilities: Vec::new(),
            joined_at: now.clone(),
            updated_at: now.clone(),
            status: AgentStatus::Active,
            agent_session_id: None,
        },
    );

    let state = SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: session_id.clone(),
        context: context.to_string(),
        status: SessionStatus::Active,
        created_at: now.clone(),
        updated_at: now,
        agents,
        tasks: BTreeMap::new(),
        leader_id: Some(leader_id.clone()),
    };

    storage::save_state(project_dir, &session_id, &state)?;
    storage::register_active(project_dir, &session_id)?;
    storage::append_log_entry(
        project_dir,
        &session_id,
        SessionTransition::SessionStarted {
            context: context.to_string(),
        },
        Some(&leader_id),
        None,
    )?;

    Ok(state)
}

/// Register an agent into an existing session.
///
/// # Errors
/// Returns `CliError` if the session is not active or on storage failures.
pub fn join_session(
    session_id: &str,
    role: SessionRole,
    runtime: &str,
    capabilities: &[String],
    name: Option<&str>,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    let agent_id = generate_agent_id(runtime);
    let display_name = name
        .map_or_else(|| format!("{runtime} {role:?}").to_lowercase(), ToString::to_string);

    let state = storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        let now = utc_now();
        state.agents.insert(
            agent_id.clone(),
            AgentRegistration {
                agent_id: agent_id.clone(),
                name: display_name.clone(),
                runtime: runtime.to_string(),
                role,
                capabilities: capabilities.to_vec(),
                joined_at: now.clone(),
                updated_at: now,
                status: AgentStatus::Active,
                agent_session_id: None,
            },
        );
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::AgentJoined {
            agent_id,
            role,
            runtime: runtime.to_string(),
        },
        None,
        None,
    )?;

    Ok(state)
}

/// End an active session (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, workers have active tasks,
/// or on storage failures.
pub fn end_session(
    session_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::EndSession)?;

        let active_tasks = state
            .tasks
            .values()
            .any(|task| task.status == TaskStatus::InProgress);
        if active_tasks {
            return Err(CliErrorKind::session_agent_conflict(
                "cannot end session with in-progress tasks",
            )
            .into());
        }

        state.status = SessionStatus::Ended;
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::SessionEnded,
        Some(actor_id),
        None,
    )?;
    storage::deregister_active(project_dir, session_id)?;

    Ok(())
}

/// Assign or change the role of an agent (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the agent is not found.
pub fn assign_role(
    session_id: &str,
    agent_id: &str,
    role: SessionRole,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let mut from_role = SessionRole::Worker;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::AssignRole)?;

        let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' not found"
            )))
        })?;
        from_role = agent.role;
        agent.role = role;
        agent.updated_at = utc_now();
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::RoleChanged {
            agent_id: agent_id.to_string(),
            from: from_role,
            to: role,
        },
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// Remove an agent from a session (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the agent is not found.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::RemoveAgent)?;

        let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' not found"
            )))
        })?;
        agent.status = AgentStatus::Removed;
        agent.updated_at = utc_now();

        for task in state.tasks.values_mut() {
            if task.assigned_to.as_deref() == Some(agent_id)
                && task.status == TaskStatus::InProgress
            {
                task.status = TaskStatus::Open;
                task.assigned_to = None;
                task.updated_at = utc_now();
            }
        }
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::AgentRemoved {
            agent_id: agent_id.to_string(),
        },
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// Transfer leadership to another agent.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the target is not found.
pub fn transfer_leader(
    session_id: &str,
    new_leader_id: &str,
    reason: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let mut old_leader = String::new();

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::TransferLeader)?;

        if !state.agents.contains_key(new_leader_id) {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "target agent '{new_leader_id}' not found"
            ))
            .into());
        }

        old_leader = state.leader_id.clone().unwrap_or_default();
        let now = utc_now();

        if let Some(old) = state.agents.get_mut(&old_leader) {
            old.role = SessionRole::Worker;
            old.updated_at.clone_from(&now);
        }
        if let Some(new) = state.agents.get_mut(new_leader_id) {
            new.role = SessionRole::Leader;
            new.updated_at = now;
        }
        state.leader_id = Some(new_leader_id.to_string());
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::LeaderTransferred {
            from: old_leader,
            to: new_leader_id.to_string(),
        },
        Some(actor_id),
        reason,
    )?;

    Ok(())
}

/// Create a work item in the session.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
///
/// # Panics
/// Panics if the internal state update fails to set the created item (unreachable).
pub fn create_task(
    session_id: &str,
    title: &str,
    context: Option<&str>,
    severity: TaskSeverity,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    let mut created_item = None;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::CreateTask)?;

        let task_id = format!("task-{}", state.tasks.len() + 1);
        let now = utc_now();
        let item = WorkItem {
            task_id: task_id.clone(),
            title: title.to_string(),
            context: context.map(ToString::to_string),
            severity,
            status: TaskStatus::Open,
            assigned_to: None,
            created_at: now.clone(),
            updated_at: now,
            created_by: Some(actor_id.to_string()),
            notes: Vec::new(),
        };
        state.tasks.insert(task_id, item.clone());
        created_item = Some(item);
        Ok(())
    })?;

    let item = created_item.expect("task was created");
    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::TaskCreated {
            task_id: item.task_id.clone(),
            title: item.title.clone(),
            severity,
        },
        Some(actor_id),
        None,
    )?;

    Ok(item)
}

/// Assign a work item to an agent (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or task/agent not found.
pub fn assign_task(
    session_id: &str,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::AssignTask)?;

        if !state.agents.contains_key(agent_id) {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' not found"
            ))
            .into());
        }

        let task = state.tasks.get_mut(task_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_not_active(format!(
                "task '{task_id}' not found"
            )))
        })?;
        task.assigned_to = Some(agent_id.to_string());
        task.status = TaskStatus::InProgress;
        task.updated_at = utc_now();
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::TaskAssigned {
            task_id: task_id.to_string(),
            agent_id: agent_id.to_string(),
        },
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// List work items, optionally filtered by status.
///
/// # Errors
/// Returns `CliError` if the session is not found.
pub fn list_tasks(
    session_id: &str,
    status_filter: Option<TaskStatus>,
    project_dir: &Path,
) -> Result<Vec<WorkItem>, CliError> {
    let state = storage::load_state(project_dir, session_id)?.ok_or_else(|| {
        CliError::from(CliErrorKind::session_not_active(format!(
            "session '{session_id}' not found"
        )))
    })?;

    let mut items: Vec<WorkItem> = state
        .tasks
        .into_values()
        .filter(|task| status_filter.is_none_or(|status| task.status == status))
        .collect();
    items.sort_unstable_by(|a, b| b.severity.cmp(&a.severity));
    Ok(items)
}

/// Update a work item's status.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn update_task(
    session_id: &str,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let mut from_status = TaskStatus::Open;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

        let task = state.tasks.get_mut(task_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_not_active(format!(
                "task '{task_id}' not found"
            )))
        })?;
        from_status = task.status;
        task.status = status;
        task.updated_at = utc_now();
        if let Some(text) = note {
            task.notes.push(TaskNote {
                timestamp: utc_now(),
                agent_id: Some(actor_id.to_string()),
                text: text.to_string(),
            });
        }
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::TaskStatusChanged {
            task_id: task_id.to_string(),
            from: from_status,
            to: status,
        },
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// Load the current session state.
///
/// # Errors
/// Returns `CliError` if the session is not found.
pub fn session_status(
    session_id: &str,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    storage::load_state(project_dir, session_id)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
    })
}

/// List all active sessions for a project.
///
/// # Errors
/// Returns `CliError` on storage failures.
pub fn list_sessions(project_dir: &Path) -> Result<Vec<SessionState>, CliError> {
    let registry = storage::load_active_registry_for(project_dir);
    let mut sessions = Vec::new();
    for session_id in registry.sessions.keys() {
        if let Some(state) = storage::load_state(project_dir, session_id)? {
            sessions.push(state);
        }
    }
    Ok(sessions)
}

fn require_active(state: &SessionState) -> Result<(), CliError> {
    if state.status != SessionStatus::Active {
        return Err(CliErrorKind::session_not_active(format!(
            "session '{}' is {:?}",
            state.session_id, state.status
        ))
        .into());
    }
    Ok(())
}

fn require_permission(
    state: &SessionState,
    actor_id: &str,
    action: SessionAction,
) -> Result<(), CliError> {
    let agent = state.agents.get(actor_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{actor_id}' not registered in session '{}'",
            state.session_id
        )))
    })?;
    if !is_permitted(agent.role, action) {
        return Err(CliErrorKind::session_permission_denied(format!(
            "{:?} cannot {:?} in session '{}'",
            agent.role, action, state.session_id
        ))
        .into());
    }
    Ok(())
}

fn generate_session_id(timestamp: &str) -> String {
    let compact = timestamp.replace([':', '-', 'T', 'Z'], "");
    let short = &compact[..compact.len().min(14)];
    format!("sess-{short}")
}

fn generate_agent_id(runtime: &str) -> String {
    let now = utc_now().replace([':', '-', 'T', 'Z'], "");
    let short = &now[..now.len().min(14)];
    format!("{runtime}-{short}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("test-service")),
            ],
            || {
                let project = tmp.path().join("project");
                test_fn(&project);
            },
        );
    }

    #[test]
    fn start_creates_session_with_leader() {
        with_temp_project(|project| {
            let state =
                start_session("test goal", project, Some("claude"), None).unwrap();
            assert_eq!(state.status, SessionStatus::Active);
            assert_eq!(state.agents.len(), 1);
            let leader = state.agents.values().next().unwrap();
            assert_eq!(leader.role, SessionRole::Leader);
            assert_eq!(leader.runtime, "claude");
        });
    }

    #[test]
    fn join_adds_agent() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("s1")).unwrap();
            let state = join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &["general".into()],
                None,
                project,
            )
            .unwrap();
            assert_eq!(state.agents.len(), 2);
        });
    }

    #[test]
    fn end_session_requires_leader() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("s2")).unwrap();
            let joined = join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
            )
            .unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .unwrap()
                .clone();
            let result = end_session(&state.session_id, &worker_id, project);
            assert!(result.is_err());
        });
    }

    #[test]
    fn task_lifecycle() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("s3")).unwrap();
            let leader_id = state.leader_id.unwrap();

            let item = create_task(
                "s3",
                "fix bug",
                Some("details"),
                TaskSeverity::High,
                &leader_id,
                project,
            )
            .unwrap();
            assert_eq!(item.status, TaskStatus::Open);

            let tasks = list_tasks("s3", None, project).unwrap();
            assert_eq!(tasks.len(), 1);

            update_task(
                "s3",
                &item.task_id,
                TaskStatus::Done,
                Some("fixed"),
                &leader_id,
                project,
            )
            .unwrap();

            let tasks = list_tasks("s3", Some(TaskStatus::Done), project).unwrap();
            assert_eq!(tasks.len(), 1);
            assert_eq!(tasks[0].notes.len(), 1);
        });
    }

    #[test]
    fn remove_agent_returns_tasks() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("s4")).unwrap();
            let leader_id = state.leader_id.unwrap();

            let joined = join_session("s4", SessionRole::Worker, "codex", &[], None, project)
                .unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .unwrap()
                .clone();

            let task = create_task(
                "s4",
                "task1",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .unwrap();
            assign_task("s4", &task.task_id, &worker_id, &leader_id, project).unwrap();

            remove_agent("s4", &worker_id, &leader_id, project).unwrap();

            let tasks = list_tasks("s4", Some(TaskStatus::Open), project).unwrap();
            assert_eq!(tasks.len(), 1);
            assert!(tasks[0].assigned_to.is_none());
        });
    }

    #[test]
    fn list_sessions_returns_active() {
        with_temp_project(|project| {
            start_session("goal1", project, Some("claude"), Some("ls1")).unwrap();
            start_session("goal2", project, Some("codex"), Some("ls2")).unwrap();
            let sessions = list_sessions(project).unwrap();
            assert_eq!(sessions.len(), 2);
        });
    }
}
