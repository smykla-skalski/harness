use std::collections::BTreeMap;
use std::path::Path;

use chrono::Utc;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::roles::{is_permitted, SessionAction};
use super::storage;
use super::types::{
    AgentRegistration, AgentStatus, SessionRole, SessionState, SessionStatus, SessionTransition,
    TaskNote, TaskSeverity, TaskStatus, WorkItem, CURRENT_VERSION,
};

/// Start a new orchestration session and register the caller as leader.
///
/// # Errors
/// Returns `CliError` on storage failures.
///
/// # Panics
/// Panics if the new session state has no leader (unreachable).
pub fn start_session(
    context: &str,
    project_dir: &Path,
    runtime: Option<&str>,
    session_id: Option<&str>,
) -> Result<SessionState, CliError> {
    let now = utc_now();
    let requested_session_id = session_id
        .filter(|value| !value.trim().is_empty())
        .map(ToString::to_string);
    let runtime_name = runtime.unwrap_or("unknown");

    let state = if let Some(session_id) = requested_session_id {
        let candidate = build_initial_state(context, &session_id, runtime_name, &now);
        if !storage::create_state(project_dir, &session_id, &candidate)? {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "session '{session_id}' already exists"
            ))
            .into());
        }
        candidate
    } else {
        let mut created = None;
        for _ in 0..8 {
            let candidate_id = generate_session_id();
            let candidate = build_initial_state(context, &candidate_id, runtime_name, &now);
            if storage::create_state(project_dir, &candidate_id, &candidate)? {
                created = Some(candidate);
                break;
            }
        }
        created.ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(
                "failed to allocate a unique session ID".to_string(),
            ))
        })?
    };

    let session_id = state.session_id.clone();
    let leader_id = state
        .leader_id
        .clone()
        .expect("new session always has a leader");

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
///
/// # Panics
/// Panics if the agent ID was not recorded during the update (unreachable).
pub fn join_session(
    session_id: &str,
    role: SessionRole,
    runtime: &str,
    capabilities: &[String],
    name: Option<&str>,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    let display_name = name.map_or_else(
        || format!("{runtime} {role:?}").to_lowercase(),
        ToString::to_string,
    );
    let mut joined_agent_id = None;

    let state = storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        let now = utc_now();
        let agent_id = next_available_agent_id(runtime, &state.agents);
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
        joined_agent_id = Some(agent_id);
        Ok(())
    })?;

    let agent_id = joined_agent_id.expect("join_session must record the new agent ID");

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
pub fn end_session(session_id: &str, actor_id: &str, project_dir: &Path) -> Result<(), CliError> {
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
        if role == SessionRole::Leader {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "use transfer-leader to assign leader role to '{agent_id}'"
            ))
            .into());
        }
        if state.leader_id.as_deref() == Some(agent_id) {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "cannot change role for current leader '{agent_id}'; use transfer-leader"
            ))
            .into());
        }
        require_active_target_agent(state, agent_id)?;

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
        if state.leader_id.as_deref() == Some(agent_id) {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "cannot remove current leader '{agent_id}'; transfer leadership first"
            ))
            .into());
        }

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
        require_active_target_agent(state, new_leader_id)?;

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
        require_active_target_agent(state, agent_id)?;

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
pub fn session_status(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
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
    if agent.status != AgentStatus::Active {
        return Err(CliErrorKind::session_permission_denied(format!(
            "agent '{actor_id}' is {} in session '{}'",
            agent_status_label(agent.status),
            state.session_id
        ))
        .into());
    }
    if !is_permitted(agent.role, action) {
        return Err(CliErrorKind::session_permission_denied(format!(
            "{:?} cannot {:?} in session '{}'",
            agent.role, action, state.session_id
        ))
        .into());
    }
    Ok(())
}

fn build_initial_state(
    context: &str,
    session_id: &str,
    runtime_name: &str,
    now: &str,
) -> SessionState {
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
            joined_at: now.to_string(),
            updated_at: now.to_string(),
            status: AgentStatus::Active,
            agent_session_id: None,
        },
    );

    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: session_id.to_string(),
        context: context.to_string(),
        status: SessionStatus::Active,
        created_at: now.to_string(),
        updated_at: now.to_string(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: Some(leader_id),
    }
}

fn require_active_target_agent(state: &SessionState, agent_id: &str) -> Result<(), CliError> {
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if agent.status != AgentStatus::Active {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is {}",
            agent_status_label(agent.status)
        ))
        .into());
    }
    Ok(())
}

fn agent_status_label(status: AgentStatus) -> &'static str {
    match status {
        AgentStatus::Active => "active",
        AgentStatus::Disconnected => "disconnected",
        AgentStatus::Removed => "removed",
    }
}

fn generate_session_id() -> String {
    format!("sess-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}

fn next_available_agent_id(runtime: &str, agents: &BTreeMap<String, AgentRegistration>) -> String {
    let base = format!("{runtime}-{}", Utc::now().format("%Y%m%d%H%M%S%f"));
    if !agents.contains_key(&base) {
        return base;
    }

    let mut suffix = 2_u32;
    loop {
        let candidate = format!("{base}-{suffix}");
        if !agents.contains_key(&candidate) {
            return candidate;
        }
        suffix += 1;
    }
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
            let state = start_session("test goal", project, Some("claude"), None).unwrap();
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
            let state = start_session("test", project, Some("claude"), Some("s1")).unwrap();
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
    fn start_session_rejects_duplicate_session_id() {
        with_temp_project(|project| {
            start_session("goal1", project, Some("claude"), Some("dup")).unwrap();

            let error = start_session("goal2", project, Some("codex"), Some("dup")).unwrap_err();

            assert_eq!(error.code(), "KSRCLI092");
            assert_eq!(session_status("dup", project).unwrap().context, "goal1");
        });
    }

    #[test]
    fn start_session_rejects_unsafe_session_id() {
        with_temp_project(|project| {
            let tmp_root = project
                .parent()
                .expect("temp project should have a parent directory");
            let escape_dir = tmp_root.join("unsafe-session");
            let unsafe_id = escape_dir.to_string_lossy().into_owned();

            let error =
                start_session("goal", project, Some("claude"), Some(&unsafe_id)).unwrap_err();

            assert_eq!(error.code(), "KSRCLI059");
            assert!(!escape_dir.join("state.json").exists());
        });
    }

    #[test]
    fn auto_generated_session_ids_are_unique() {
        with_temp_project(|project| {
            let first = start_session("goal1", project, Some("claude"), None).unwrap();
            let second = start_session("goal2", project, Some("codex"), None).unwrap();

            assert_ne!(first.session_id, second.session_id);
        });
    }

    #[test]
    fn join_same_runtime_keeps_distinct_agents() {
        with_temp_project(|project| {
            start_session("test", project, Some("claude"), Some("join-unique")).unwrap();

            let first = join_session(
                "join-unique",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
            )
            .unwrap();
            let second = join_session(
                "join-unique",
                SessionRole::Reviewer,
                "codex",
                &[],
                None,
                project,
            )
            .unwrap();

            assert_eq!(first.agents.len(), 2);
            assert_eq!(second.agents.len(), 3);
            let codex_ids: Vec<_> = second
                .agents
                .keys()
                .filter(|id| id.starts_with("codex-"))
                .collect();
            assert_eq!(codex_ids.len(), 2);
        });
    }

    #[test]
    fn end_session_requires_leader() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s2")).unwrap();
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
            let state = start_session("test", project, Some("claude"), Some("s3")).unwrap();
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
            let state = start_session("test", project, Some("claude"), Some("s4")).unwrap();
            let leader_id = state.leader_id.unwrap();

            let joined =
                join_session("s4", SessionRole::Worker, "codex", &[], None, project).unwrap();
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
    fn removed_agent_loses_mutation_permissions() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("perm")).unwrap();
            let leader_id = state.leader_id.unwrap();

            let joined =
                join_session("perm", SessionRole::Worker, "codex", &[], None, project).unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .unwrap()
                .clone();
            let task = create_task(
                "perm",
                "task1",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .unwrap();

            remove_agent("perm", &worker_id, &leader_id, project).unwrap();

            let error = update_task(
                "perm",
                &task.task_id,
                TaskStatus::Done,
                None,
                &worker_id,
                project,
            )
            .unwrap_err();
            assert_eq!(error.code(), "KSRCLI091");
        });
    }

    #[test]
    fn assign_role_rejects_leader_changes() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("roles")).unwrap();
            let leader_id = state.leader_id.unwrap();
            let joined =
                join_session("roles", SessionRole::Worker, "codex", &[], None, project).unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .unwrap()
                .clone();

            let error = assign_role(
                "roles",
                &worker_id,
                SessionRole::Leader,
                &leader_id,
                project,
            )
            .unwrap_err();

            assert_eq!(error.code(), "KSRCLI092");
        });
    }

    #[test]
    fn assign_task_requires_active_assignee() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("assign")).unwrap();
            let leader_id = state.leader_id.unwrap();
            let joined =
                join_session("assign", SessionRole::Worker, "codex", &[], None, project).unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .unwrap()
                .clone();
            let task = create_task(
                "assign",
                "task1",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .unwrap();

            remove_agent("assign", &worker_id, &leader_id, project).unwrap();

            let error =
                assign_task("assign", &task.task_id, &worker_id, &leader_id, project).unwrap_err();
            assert_eq!(error.code(), "KSRCLI092");
        });
    }

    #[test]
    fn transfer_leader_requires_active_target() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("transfer")).unwrap();
            let leader_id = state.leader_id.unwrap();
            let joined =
                join_session("transfer", SessionRole::Worker, "codex", &[], None, project).unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .unwrap()
                .clone();

            remove_agent("transfer", &worker_id, &leader_id, project).unwrap();

            let error =
                transfer_leader("transfer", &worker_id, None, &leader_id, project).unwrap_err();
            assert_eq!(error.code(), "KSRCLI092");
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
