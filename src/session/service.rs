use std::cmp::Reverse;
use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};

use chrono::{Duration, Utc};
use serde_json::Value;

use crate::agents::runtime;
use crate::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalPayload, SignalPriority, read_acknowledged_signals,
    read_acknowledgments, read_pending_signals,
};
use crate::agents::service as agents_service;
use crate::daemon::index as daemon_index;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::workspace::utc_now;

use super::roles::{SessionAction, is_permitted};
use super::storage;
use super::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, PendingLeaderTransfer, SessionMetrics,
    SessionRole, SessionSignalRecord, SessionSignalStatus, SessionState, SessionStatus,
    SessionTransition, TaskCheckpoint, TaskCheckpointSummary, TaskNote, TaskSeverity, TaskSource,
    TaskStatus, WorkItem,
};

const DEFAULT_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS: i64 = 300;

/// Task-specific fields for `create_task_with_source`.
pub struct TaskSpec<'a> {
    pub title: &'a str,
    pub context: Option<&'a str>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<&'a str>,
    pub source: TaskSource,
    pub observe_issue_id: Option<&'a str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedRuntimeSessionAgent {
    pub orchestration_session_id: String,
    pub agent_id: String,
}

/// Start a new orchestration session and register the caller as leader.
///
/// # Errors
/// Returns `CliError` on storage failures.
///
/// # Panics
/// Panics if the new session state has no leader.
pub fn start_session(
    context: &str,
    project_dir: &Path,
    runtime_name: Option<&str>,
    session_id: Option<&str>,
) -> Result<SessionState, CliError> {
    let now = utc_now();
    let runtime_name = runtime_name.ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(
            "session start requires --runtime for leader session tracking".to_string(),
        ))
    })?;
    let leader_runtime = resolve_registered_runtime(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "session start requires a known runtime, got '{runtime_name}'"
        )))
    })?;
    let leader_agent_session_id =
        agents_service::resolve_known_session_id(leader_runtime, project_dir, None)?;
    let state = create_initial_session(
        context,
        runtime_name,
        session_id,
        leader_agent_session_id.as_deref(),
        &now,
        project_dir,
    )?;
    let leader_id = state
        .leader_id
        .as_deref()
        .expect("new session always has a leader");

    storage::register_active(project_dir, &state.session_id)?;
    let _ = storage::record_project_origin(project_dir);
    storage::append_log_entry(
        project_dir,
        &state.session_id,
        SessionTransition::SessionStarted {
            context: context.to_string(),
        },
        Some(leader_id),
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
/// Panics if the agent ID was not recorded during the update.
pub fn join_session(
    session_id: &str,
    role: SessionRole,
    runtime_name: &str,
    capabilities: &[String],
    name: Option<&str>,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    let display_name = name.map_or_else(
        || format!("{runtime_name} {role:?}").to_lowercase(),
        ToString::to_string,
    );
    let joined_runtime = resolve_registered_runtime(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent join requires a known runtime, got '{runtime_name}'"
        )))
    })?;
    let agent_session_id =
        agents_service::resolve_known_session_id(joined_runtime, project_dir, None)?;
    let now = utc_now();
    let mut joined_agent_id = None;

    let state = storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        let agent_id = next_available_agent_id(runtime_name, &state.agents);
        state.agents.insert(
            agent_id.clone(),
            AgentRegistration {
                agent_id: agent_id.clone(),
                name: display_name.clone(),
                runtime: runtime_name.to_string(),
                role,
                capabilities: capabilities.to_vec(),
                joined_at: now.clone(),
                updated_at: now.clone(),
                status: AgentStatus::Active,
                agent_session_id: agent_session_id.clone(),
                last_activity_at: Some(now.clone()),
                current_task_id: None,
                runtime_capabilities: runtime_capabilities(runtime_name),
            },
        );
        joined_agent_id = Some(agent_id);
        refresh_session(state, &now);
        Ok(())
    })?;

    let agent_id = joined_agent_id.expect("join_session must record the new agent ID");
    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::AgentJoined {
            agent_id,
            role,
            runtime: runtime_name.to_string(),
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
    let now = utc_now();

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::EndSession)?;

        let active_tasks = state.tasks.values().any(|task| {
            matches!(
                task.status,
                TaskStatus::InProgress | TaskStatus::InReview | TaskStatus::Blocked
            )
        });
        if active_tasks {
            return Err(CliErrorKind::session_agent_conflict(
                "cannot end session with in-progress tasks",
            )
            .into());
        }

        touch_agent(state, actor_id, &now);
        state.status = SessionStatus::Ended;
        state.archived_at = Some(now.clone());
        refresh_session(state, &now);
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
    reason: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
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
        agent.updated_at.clone_from(&now);
        agent.last_activity_at = Some(now.clone());
        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
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
        reason,
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
    let now = utc_now();

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::RemoveAgent)?;
        if state.leader_id.as_deref() == Some(agent_id) {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "cannot remove current leader '{agent_id}'; transfer leadership first"
            ))
            .into());
        }

        {
            let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
                CliError::from(CliErrorKind::session_agent_conflict(format!(
                    "agent '{agent_id}' not found"
                )))
            })?;
            agent.status = AgentStatus::Removed;
            agent.updated_at.clone_from(&now);
            agent.last_activity_at = Some(now.clone());
            agent.current_task_id = None;
        }
        clear_pending_leader_transfer(state, agent_id);

        for task in state.tasks.values_mut() {
            if task.assigned_to.as_deref() == Some(agent_id)
                && matches!(
                    task.status,
                    TaskStatus::InProgress | TaskStatus::InReview | TaskStatus::Blocked
                )
            {
                task.status = TaskStatus::Open;
                task.assigned_to = None;
                task.updated_at.clone_from(&now);
                task.blocked_reason = None;
                task.completed_at = None;
            }
        }

        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
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
    let now = utc_now();
    let mut transfer = None;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::TransferLeader)?;
        transfer = Some(plan_leader_transfer(
            state,
            new_leader_id,
            actor_id,
            reason,
            &now,
        )?);
        Ok(())
    })?;

    let transfer = transfer.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "leader transfer did not persist state".to_string(),
        ))
    })?;

    if let Some(request) = transfer.pending_request {
        storage::append_log_entry(
            project_dir,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id,
                to: request.new_leader_id,
            },
            Some(actor_id),
            request.reason.as_deref(),
        )?;
        return Ok(());
    }

    append_leader_transfer_logs(
        project_dir,
        session_id,
        actor_id,
        transfer.outcome.as_ref().ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "leader transfer did not persist outcome".to_string(),
            ))
        })?,
    )
}

/// Create a work item in the session.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
pub fn create_task(
    session_id: &str,
    title: &str,
    context: Option<&str>,
    severity: TaskSeverity,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    let spec = TaskSpec {
        title,
        context,
        severity,
        suggested_fix: None,
        source: TaskSource::Manual,
        observe_issue_id: None,
    };
    create_task_with_source(session_id, &spec, actor_id, project_dir)
}

/// Create a task with explicit source metadata.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
pub fn create_task_with_source(
    session_id: &str,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    let now = utc_now();
    let mut created_item = None;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::CreateTask)?;

        let task_id = next_task_id(&state.tasks);
        let item_timestamps = now.clone();
        let item = WorkItem {
            task_id: task_id.clone(),
            title: spec.title.to_string(),
            context: spec.context.map(ToString::to_string),
            severity: spec.severity,
            status: TaskStatus::Open,
            assigned_to: None,
            created_at: item_timestamps.clone(),
            updated_at: item_timestamps,
            created_by: Some(actor_id.to_string()),
            notes: Vec::new(),
            suggested_fix: spec.suggested_fix.map(ToString::to_string),
            source: spec.source,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
        };
        state.tasks.insert(task_id, item.clone());
        created_item = Some(item);
        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
        Ok(())
    })?;

    let item = created_item.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task creation did not persist state".to_string(),
        ))
    })?;
    let transition = if spec.source == TaskSource::Observe {
        SessionTransition::ObserveTaskCreated {
            task_id: item.task_id.clone(),
            title: item.title.clone(),
            severity: spec.severity,
            issue_id: spec.observe_issue_id.map(ToString::to_string),
        }
    } else {
        SessionTransition::TaskCreated {
            task_id: item.task_id.clone(),
            title: item.title.clone(),
            severity: spec.severity,
        }
    };
    storage::append_log_entry(project_dir, session_id, transition, Some(actor_id), None)?;

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
    let now = utc_now();

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::AssignTask)?;
        require_active_target_agent(state, agent_id)?;

        let previous_assignee = state
            .tasks
            .get(task_id)
            .ok_or_else(|| task_not_found(task_id))?
            .assigned_to
            .clone();
        if let Some(previous_assignee) = previous_assignee.as_deref() {
            clear_agent_current_task(state, previous_assignee, task_id, &now);
        }

        let task = state
            .tasks
            .get_mut(task_id)
            .ok_or_else(|| task_not_found(task_id))?;
        task.assigned_to = Some(agent_id.to_string());
        task.status = TaskStatus::InProgress;
        task.updated_at.clone_from(&now);
        task.blocked_reason = None;
        task.completed_at = None;

        if let Some(agent) = state.agents.get_mut(agent_id) {
            agent.current_task_id = Some(task_id.to_string());
            agent.updated_at.clone_from(&now);
            agent.last_activity_at = Some(now.clone());
        }

        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
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
    let state = load_state_or_err(session_id, project_dir)?;
    let mut items: Vec<WorkItem> = state
        .tasks
        .into_values()
        .filter(|task| status_filter.is_none_or(|status| task.status == status))
        .collect();
    items.sort_unstable_by_key(|item| (Reverse(item.severity), Reverse(item.updated_at.clone())));
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
    let now = utc_now();
    let mut from_status = TaskStatus::Open;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

        let assigned_to = state
            .tasks
            .get(task_id)
            .ok_or_else(|| task_not_found(task_id))?
            .assigned_to
            .clone();
        let task = state
            .tasks
            .get_mut(task_id)
            .ok_or_else(|| task_not_found(task_id))?;

        from_status = task.status;
        task.status = status;
        task.updated_at.clone_from(&now);
        if let Some(text) = note {
            task.notes.push(TaskNote {
                timestamp: now.clone(),
                agent_id: Some(actor_id.to_string()),
                text: text.to_string(),
            });
        }

        match status {
            TaskStatus::Done => {
                task.completed_at = Some(now.clone());
                task.blocked_reason = None;
            }
            TaskStatus::Blocked => {
                task.blocked_reason = note.map(ToString::to_string);
                task.completed_at = None;
            }
            TaskStatus::Open | TaskStatus::InProgress | TaskStatus::InReview => {
                task.blocked_reason = None;
                task.completed_at = None;
            }
        }

        if let Some(assigned_to) = assigned_to.as_deref() {
            if status == TaskStatus::InProgress {
                if let Some(agent) = state.agents.get_mut(assigned_to) {
                    agent.current_task_id = Some(task_id.to_string());
                    agent.updated_at.clone_from(&now);
                    agent.last_activity_at = Some(now.clone());
                }
            } else {
                clear_agent_current_task(state, assigned_to, task_id, &now);
            }
        }

        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
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

/// Record an append-only task checkpoint.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn record_task_checkpoint(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    summary: &str,
    progress: u8,
    project_dir: &Path,
) -> Result<TaskCheckpoint, CliError> {
    ensure_valid_progress(progress)?;

    let now = utc_now();
    let mut checkpoint = None;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

        let assigned_to = state
            .tasks
            .get(task_id)
            .ok_or_else(|| task_not_found(task_id))?
            .assigned_to
            .clone();
        let created = TaskCheckpoint {
            checkpoint_id: generate_checkpoint_id(task_id),
            task_id: task_id.to_string(),
            recorded_at: now.clone(),
            actor_id: Some(actor_id.to_string()),
            summary: summary.to_string(),
            progress,
        };

        let task = state
            .tasks
            .get_mut(task_id)
            .ok_or_else(|| task_not_found(task_id))?;
        if task.status == TaskStatus::Open {
            task.status = TaskStatus::InProgress;
        }
        task.updated_at.clone_from(&now);
        task.checkpoint_summary = Some(TaskCheckpointSummary::from(&created));

        if let Some(assigned_to) = assigned_to.as_deref()
            && let Some(agent) = state.agents.get_mut(assigned_to)
        {
            agent.current_task_id = Some(task_id.to_string());
            agent.updated_at.clone_from(&now);
            agent.last_activity_at = Some(now.clone());
        }

        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
        checkpoint = Some(created);
        Ok(())
    })?;

    let checkpoint = checkpoint.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task checkpoint did not persist state".to_string(),
        ))
    })?;
    storage::append_task_checkpoint(project_dir, session_id, task_id, &checkpoint)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::TaskCheckpointRecorded {
            task_id: task_id.to_string(),
            checkpoint_id: checkpoint.checkpoint_id.clone(),
            progress,
        },
        Some(actor_id),
        None,
    )?;
    Ok(checkpoint)
}

/// Send a file-backed signal to a running agent session.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target agent is not
/// active, or the runtime adapter is unknown.
pub fn send_signal(
    session_id: &str,
    agent_id: &str,
    command: &str,
    message: &str,
    action_hint: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<SessionSignalRecord, CliError> {
    let now = utc_now();
    let mut runtime_name = String::new();
    let mut target_agent_session_id = None;

    storage::update_state(project_dir, session_id, |state| {
        require_active(state)?;
        require_permission(state, actor_id, SessionAction::SendSignal)?;
        let target_agent = state.agents.get(agent_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' not found"
            )))
        })?;
        if target_agent.status != AgentStatus::Active {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' is {}",
                agent_status_label(target_agent.status)
            ))
            .into());
        }

        runtime_name.clone_from(&target_agent.runtime);
        target_agent_session_id.clone_from(&target_agent.agent_session_id);
        touch_agent(state, actor_id, &now);
        refresh_session(state, &now);
        Ok(())
    })?;

    let runtime = runtime::runtime_for_name(&runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{runtime_name}'"
        )))
    })?;

    let signal = Signal {
        signal_id: generate_signal_id(),
        version: 1,
        created_at: now,
        expires_at: (Utc::now() + Duration::minutes(15))
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string(),
        source_agent: actor_id.to_string(),
        command: command.to_string(),
        priority: SignalPriority::Normal,
        payload: SignalPayload {
            message: message.to_string(),
            action_hint: action_hint.map(ToString::to_string),
            related_files: Vec::new(),
            metadata: Value::Null,
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: Some(format!("{session_id}:{agent_id}:{command}")),
        },
    };

    let signal_session_id = target_agent_session_id.as_deref().unwrap_or(session_id);
    runtime.write_signal(project_dir, signal_session_id, &signal)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::SignalSent {
            signal_id: signal.signal_id.clone(),
            agent_id: agent_id.to_string(),
            command: command.to_string(),
        },
        Some(actor_id),
        None,
    )?;

    Ok(SessionSignalRecord {
        runtime: runtime_name,
        agent_id: agent_id.to_string(),
        session_id: session_id.to_string(),
        status: SessionSignalStatus::Pending,
        signal,
        acknowledgment: None,
    })
}

/// List all signals for a session, optionally narrowed to one agent.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or runtime signal
/// directories cannot be read.
pub fn list_signals(
    session_id: &str,
    agent_filter: Option<&str>,
    project_dir: &Path,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let state = load_state_or_err(session_id, project_dir)?;
    let mut signals = Vec::new();

    for (agent_id, agent) in state.agents {
        if agent_filter.is_some_and(|filter| filter != agent_id) {
            continue;
        }
        let Some(runtime) = runtime::runtime_for_name(&agent.runtime) else {
            continue;
        };
        let signal_dirs: Vec<_> =
            runtime::signal_session_keys(session_id, agent.agent_session_id.as_deref())
                .into_iter()
                .map(|signal_session_id| runtime.signal_dir(project_dir, &signal_session_id))
                .collect();
        signals.extend(signal_records_for_dirs(
            &agent.runtime,
            &agent_id,
            session_id,
            &signal_dirs,
        )?);
    }

    signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
    Ok(signals)
}

/// Resolve the orchestration session and agent owning a runtime session ID.
///
/// # Errors
/// Returns `CliError` when the active session registry cannot be read or the
/// runtime session is ambiguous across active sessions.
pub fn resolve_session_agent_for_runtime_session(
    project_dir: &Path,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    let active_session_ids: Vec<_> = storage::load_active_registry_for(project_dir)
        .sessions
        .into_keys()
        .collect();
    let mut matches = Vec::new();

    for session_id in active_session_ids {
        let Some(state) = storage::load_state(project_dir, &session_id)? else {
            continue;
        };
        for (agent_id, agent) in &state.agents {
            if agent.status != AgentStatus::Active || agent.runtime != runtime_name {
                continue;
            }
            let matches_runtime_session = agent.agent_session_id.as_deref()
                == Some(runtime_session_id)
                || (agent.agent_session_id.is_none() && state.session_id == runtime_session_id);
            if matches_runtime_session {
                matches.push(ResolvedRuntimeSessionAgent {
                    orchestration_session_id: state.session_id.clone(),
                    agent_id: agent_id.clone(),
                });
            }
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

/// Persist a signal acknowledgment into the authoritative session audit log.
///
/// # Errors
/// Returns `CliError` if the session log cannot be read or updated.
pub fn record_signal_acknowledgment(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
) -> Result<(), CliError> {
    let already_logged = storage::load_log_entries(project_dir, session_id)?
        .into_iter()
        .any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::SignalAcknowledged { signal_id: ref existing, .. }
                    if existing == signal_id
            )
        });
    if already_logged {
        return Ok(());
    }

    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::SignalAcknowledged {
            signal_id: signal_id.to_string(),
            agent_id: agent_id.to_string(),
            result,
        },
        Some(agent_id),
        None,
    )
}

fn signal_records_for_dirs(
    runtime_name: &str,
    agent_id: &str,
    session_id: &str,
    signal_dirs: &[PathBuf],
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let mut signals_by_id = BTreeMap::new();
    let mut acknowledgments_by_id = BTreeMap::new();

    for signal_dir in signal_dirs {
        for signal in read_pending_signals(signal_dir)? {
            signals_by_id
                .entry(signal.signal_id.clone())
                .or_insert((signal, false));
        }
        for signal in read_acknowledged_signals(signal_dir)? {
            signals_by_id.insert(signal.signal_id.clone(), (signal, true));
        }
        for acknowledgment in read_acknowledgments(signal_dir)? {
            acknowledgments_by_id
                .entry(acknowledgment.signal_id.clone())
                .or_insert(acknowledgment);
        }
    }

    Ok(signals_by_id
        .into_values()
        .map(|(signal, was_acknowledged)| {
            let acknowledgment = acknowledgments_by_id.remove(&signal.signal_id);
            let status = acknowledgment.as_ref().map_or_else(
                || {
                    if was_acknowledged {
                        SessionSignalStatus::Acknowledged
                    } else {
                        SessionSignalStatus::Pending
                    }
                },
                |ack| SessionSignalStatus::from_ack_result(ack.result),
            );
            SessionSignalRecord {
                runtime: runtime_name.to_string(),
                agent_id: agent_id.to_string(),
                session_id: session_id.to_string(),
                status,
                signal,
                acknowledgment,
            }
        })
        .collect())
}

/// Load the current session state.
///
/// # Errors
/// Returns `CliError` if the session is not found.
pub fn session_status(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
    let mut state = load_state_or_err(session_id, project_dir)?;
    state.metrics = SessionMetrics::recalculate(&state);
    Ok(state)
}

/// List sessions for a project.
///
/// # Errors
/// Returns `CliError` on storage failures.
pub fn list_sessions(project_dir: &Path, include_all: bool) -> Result<Vec<SessionState>, CliError> {
    let session_ids = if include_all {
        storage::list_known_session_ids(project_dir)?
    } else {
        storage::load_active_registry_for(project_dir)
            .sessions
            .into_keys()
            .collect()
    };

    let mut sessions = Vec::new();
    for session_id in session_ids {
        if let Some(mut state) = storage::load_state(project_dir, &session_id)? {
            state.metrics = SessionMetrics::recalculate(&state);
            sessions.push(state);
        }
    }
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(sessions)
}

/// List sessions across all known project contexts.
///
/// Uses daemon index discovery to find sessions regardless of which project
/// directory the caller is running from.
///
/// # Errors
/// Returns `CliError` on discovery failures.
pub fn list_sessions_global(include_all: bool) -> Result<Vec<SessionState>, CliError> {
    let resolved = daemon_index::discover_sessions(include_all)?;
    let mut sessions: Vec<SessionState> = resolved
        .into_iter()
        .map(|entry| {
            let mut state = entry.state;
            state.metrics = SessionMetrics::recalculate(&state);
            state
        })
        .collect();
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(sessions)
}

/// Resolve the effective project directory for a session command.
///
/// Checks the local project directory first (fast path). If the session is
/// not found there, searches across all project contexts using the daemon
/// index. Returns `context_root` when the original project directory is
/// unavailable - this works because `project_context_dir` is idempotent
/// for paths already under the projects root.
///
/// # Errors
/// Returns `CliError` if the session cannot be found in any project.
pub fn resolve_session_project_dir(
    session_id: &str,
    local_project_dir: &Path,
) -> Result<PathBuf, CliError> {
    if storage::load_state(local_project_dir, session_id)?.is_some() {
        return Ok(local_project_dir.to_path_buf());
    }
    let resolved = daemon_index::resolve_session(session_id)?;
    Ok(resolved
        .project
        .project_dir
        .unwrap_or(resolved.project.context_root))
}

fn create_initial_session(
    context: &str,
    runtime_name: &str,
    session_id: Option<&str>,
    agent_session_id: Option<&str>,
    now: &str,
    project_dir: &Path,
) -> Result<SessionState, CliError> {
    if let Some(session_id) = session_id
        .filter(|value| !value.trim().is_empty())
        .map(ToString::to_string)
    {
        let candidate =
            build_initial_state(context, &session_id, runtime_name, agent_session_id, now);
        if !storage::create_state(project_dir, &session_id, &candidate)? {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "session '{session_id}' already exists"
            ))
            .into());
        }
        return Ok(candidate);
    }

    for _ in 0..8 {
        let session_id = generate_session_id();
        let candidate =
            build_initial_state(context, &session_id, runtime_name, agent_session_id, now);
        if storage::create_state(project_dir, &session_id, &candidate)? {
            return Ok(candidate);
        }
    }

    Err(
        CliErrorKind::session_agent_conflict("failed to allocate a unique session ID".to_string())
            .into(),
    )
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
    agent_session_id: Option<&str>,
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
            agent_session_id: agent_session_id.map(ToString::to_string),
            last_activity_at: Some(now.to_string()),
            current_task_id: None,
            runtime_capabilities: runtime_capabilities(runtime_name),
        },
    );

    let mut state = SessionState {
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
        archived_at: None,
        last_activity_at: Some(now.to_string()),
        observe_id: Some(format!("observe-{session_id}")),
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    };
    refresh_session(&mut state, now);
    state
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

fn resolve_registered_runtime(runtime_name: &str) -> Option<HookAgent> {
    match runtime_name {
        "claude" => Some(HookAgent::Claude),
        "copilot" => Some(HookAgent::Copilot),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

fn load_state_or_err(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
    storage::load_state(project_dir, session_id)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
    })
}

fn refresh_session(state: &mut SessionState, now: &str) {
    state.updated_at = now.to_string();
    state.last_activity_at = Some(now.to_string());
    state.metrics = SessionMetrics::recalculate(state);
}

fn touch_agent(state: &mut SessionState, agent_id: &str, now: &str) {
    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}

fn clear_pending_leader_transfer(state: &mut SessionState, agent_id: &str) {
    if state
        .pending_leader_transfer
        .as_ref()
        .is_some_and(|request| {
            request.requested_by == agent_id
                || request.current_leader_id == agent_id
                || request.new_leader_id == agent_id
        })
    {
        state.pending_leader_transfer = None;
    }
}

fn leader_unresponsive_timeout_seconds() -> i64 {
    env::var("HARNESS_SESSION_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS)
}

fn agent_is_unresponsive(state: &SessionState, agent_id: &str, now: &str) -> bool {
    let Some(last_activity_at) = state
        .agents
        .get(agent_id)
        .and_then(|agent| agent.last_activity_at.as_deref())
    else {
        return true;
    };
    let Ok(now) = chrono::DateTime::parse_from_rfc3339(now) else {
        return false;
    };
    let Ok(last_activity_at) = chrono::DateTime::parse_from_rfc3339(last_activity_at) else {
        return false;
    };
    (now - last_activity_at).num_seconds() >= leader_unresponsive_timeout_seconds()
}

#[derive(Debug)]
struct LeaderTransferOutcome {
    old_leader: String,
    new_leader_id: String,
    confirmed_by: Option<String>,
    reason: Option<String>,
    log_request_before_transfer: bool,
}

#[derive(Debug)]
struct LeaderTransferPlan {
    pending_request: Option<PendingLeaderTransfer>,
    outcome: Option<LeaderTransferOutcome>,
}

fn plan_leader_transfer(
    state: &mut SessionState,
    new_leader_id: &str,
    actor_id: &str,
    reason: Option<&str>,
    now: &str,
) -> Result<LeaderTransferPlan, CliError> {
    require_active_target_agent(state, new_leader_id)?;
    let old_leader = state.leader_id.clone().unwrap_or_default();
    reject_redundant_leader_transfer(state, &old_leader, new_leader_id)?;

    if should_defer_leader_transfer(state, &old_leader, actor_id, now) {
        let request = PendingLeaderTransfer {
            requested_by: actor_id.to_string(),
            current_leader_id: old_leader,
            new_leader_id: new_leader_id.to_string(),
            requested_at: now.to_string(),
            reason: reason.map(ToString::to_string),
        };
        state.pending_leader_transfer = Some(request.clone());
        touch_agent(state, actor_id, now);
        refresh_session(state, now);
        return Ok(LeaderTransferPlan {
            pending_request: Some(request),
            outcome: None,
        });
    }

    let outcome = apply_leader_transfer(state, old_leader, new_leader_id, actor_id, reason, now);
    Ok(LeaderTransferPlan {
        pending_request: None,
        outcome: Some(outcome),
    })
}

fn reject_redundant_leader_transfer(
    state: &SessionState,
    old_leader: &str,
    new_leader_id: &str,
) -> Result<(), CliError> {
    if old_leader == new_leader_id {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{new_leader_id}' already leads session '{}'",
            state.session_id
        ))
        .into());
    }
    Ok(())
}

fn should_defer_leader_transfer(
    state: &SessionState,
    old_leader: &str,
    actor_id: &str,
    now: &str,
) -> bool {
    old_leader != actor_id
        && !old_leader.is_empty()
        && !agent_is_unresponsive(state, old_leader, now)
}

fn apply_leader_transfer(
    state: &mut SessionState,
    old_leader: String,
    new_leader_id: &str,
    actor_id: &str,
    reason: Option<&str>,
    now: &str,
) -> LeaderTransferOutcome {
    let leader_is_actor = old_leader == actor_id;
    let prior_request = state.pending_leader_transfer.take();
    update_leader_roles(state, &old_leader, new_leader_id, now);
    state.leader_id = Some(new_leader_id.to_string());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);

    LeaderTransferOutcome {
        old_leader,
        new_leader_id: new_leader_id.to_string(),
        confirmed_by: if leader_is_actor && prior_request.is_some() {
            Some(actor_id.to_string())
        } else {
            None
        },
        reason: reason
            .map(ToString::to_string)
            .or_else(|| prior_request.and_then(|request| request.reason)),
        log_request_before_transfer: !leader_is_actor,
    }
}

fn update_leader_roles(state: &mut SessionState, old_leader: &str, new_leader_id: &str, now: &str) {
    if let Some(old) = state.agents.get_mut(old_leader) {
        old.role = SessionRole::Worker;
        old.updated_at = now.to_string();
        old.last_activity_at = Some(now.to_string());
    }
    if let Some(new) = state.agents.get_mut(new_leader_id) {
        new.role = SessionRole::Leader;
        new.updated_at = now.to_string();
        new.last_activity_at = Some(now.to_string());
    }
}

fn append_leader_transfer_logs(
    project_dir: &Path,
    session_id: &str,
    actor_id: &str,
    outcome: &LeaderTransferOutcome,
) -> Result<(), CliError> {
    if outcome.log_request_before_transfer {
        storage::append_log_entry(
            project_dir,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        )?;
    }
    if let Some(confirmed_by) = outcome.confirmed_by.as_deref() {
        storage::append_log_entry(
            project_dir,
            session_id,
            SessionTransition::LeaderTransferConfirmed {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
                confirmed_by: confirmed_by.to_string(),
            },
            Some(confirmed_by),
            outcome.reason.as_deref(),
        )?;
    }
    storage::append_log_entry(
        project_dir,
        session_id,
        SessionTransition::LeaderTransferred {
            from: outcome.old_leader.clone(),
            to: outcome.new_leader_id.clone(),
        },
        Some(actor_id),
        outcome.reason.as_deref(),
    )?;
    Ok(())
}

fn clear_agent_current_task(state: &mut SessionState, agent_id: &str, task_id: &str, now: &str) {
    if let Some(agent) = state.agents.get_mut(agent_id)
        && agent.current_task_id.as_deref() == Some(task_id)
    {
        agent.current_task_id = None;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}

fn runtime_capabilities(runtime_name: &str) -> runtime::RuntimeCapabilities {
    runtime::runtime_for_name(runtime_name).map_or_else(
        || runtime::RuntimeCapabilities {
            runtime: runtime_name.to_string(),
            ..runtime::RuntimeCapabilities::default()
        },
        super::super::agents::runtime::AgentRuntime::capabilities,
    )
}

fn task_not_found(task_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("task '{task_id}' not found")).into()
}

fn ensure_valid_progress(progress: u8) -> Result<(), CliError> {
    if progress > 100 {
        return Err(CliErrorKind::workflow_parse(format!(
            "task checkpoint progress '{progress}' must be between 0 and 100"
        ))
        .into());
    }
    Ok(())
}

fn next_task_id(tasks: &BTreeMap<String, WorkItem>) -> String {
    let mut suffix = tasks.len() + 1;
    loop {
        let candidate = format!("task-{suffix}");
        if !tasks.contains_key(&candidate) {
            return candidate;
        }
        suffix += 1;
    }
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

fn next_available_agent_id(
    runtime_name: &str,
    agents: &BTreeMap<String, AgentRegistration>,
) -> String {
    let base = format!("{runtime_name}-{}", Utc::now().format("%Y%m%d%H%M%S%f"));
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

fn generate_checkpoint_id(task_id: &str) -> String {
    format!("{task_id}-cp-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}

fn generate_signal_id() -> String {
    format!("sig-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
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
            let state = start_session("test goal", project, Some("claude"), None).expect("start");
            assert_eq!(state.status, SessionStatus::Active);
            assert_eq!(state.agents.len(), 1);
            assert_eq!(state.metrics.agent_count, 1);
            let leader = state.agents.values().next().expect("leader");
            assert_eq!(leader.role, SessionRole::Leader);
            assert_eq!(leader.runtime, "claude");
            assert_eq!(leader.agent_session_id.as_deref(), Some("test-service"));
            assert_eq!(leader.runtime_capabilities.runtime, "claude");
            assert!(leader.last_activity_at.is_some());
        });
    }

    #[test]
    fn join_adds_agent() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s1")).expect("start");
            let state = join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &["general".into()],
                None,
                project,
            )
            .expect("join");
            assert_eq!(state.agents.len(), 2);
            assert_eq!(state.metrics.agent_count, 2);
        });
    }

    #[test]
    fn start_session_rejects_duplicate_session_id() {
        with_temp_project(|project| {
            start_session("goal1", project, Some("claude"), Some("dup")).expect("first");
            let error =
                start_session("goal2", project, Some("codex"), Some("dup")).expect_err("dup");

            assert_eq!(error.code(), "KSRCLI092");
            assert_eq!(
                session_status("dup", project).expect("status").context,
                "goal1"
            );
        });
    }

    #[test]
    fn start_session_rejects_unsafe_session_id() {
        with_temp_project(|project| {
            let tmp_root = project.parent().expect("parent");
            let escape_dir = tmp_root.join("unsafe-session");
            let unsafe_id = escape_dir.to_string_lossy().into_owned();

            let error =
                start_session("goal", project, Some("claude"), Some(&unsafe_id)).expect_err("id");

            assert_eq!(error.code(), "KSRCLI059");
            assert!(!escape_dir.join("state.json").exists());
        });
    }

    #[test]
    fn start_session_requires_known_runtime() {
        with_temp_project(|project| {
            let missing_runtime = start_session("goal", project, None, Some("no-runtime"))
                .expect_err("runtime is required");
            assert_eq!(missing_runtime.code(), "KSRCLI092");

            let unknown_runtime = start_session("goal", project, Some("unknown"), Some("bad"))
                .expect_err("unknown runtime should be rejected");
            assert_eq!(unknown_runtime.code(), "KSRCLI092");
        });
    }

    #[test]
    fn auto_generated_session_ids_are_unique() {
        with_temp_project(|project| {
            let first = start_session("goal1", project, Some("claude"), None).expect("first");
            let second = start_session("goal2", project, Some("codex"), None).expect("second");
            assert_ne!(first.session_id, second.session_id);
        });
    }

    #[test]
    fn join_same_runtime_keeps_distinct_agents() {
        with_temp_project(|project| {
            start_session("test", project, Some("claude"), Some("join-unique")).expect("start");

            let (first, second) =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-worker"))], || {
                    let first = join_session(
                        "join-unique",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("first");
                    let second = join_session(
                        "join-unique",
                        SessionRole::Reviewer,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("second");
                    (first, second)
                });

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
    fn join_records_runtime_session_id_when_available() {
        with_temp_project(|project| {
            start_session("test", project, Some("claude"), Some("join-runtime")).unwrap();

            let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-worker"))], || {
                join_session(
                    "join-runtime",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                )
                .unwrap()
            });

            let codex_worker = joined
                .agents
                .values()
                .find(|agent| agent.runtime == "codex")
                .expect("codex worker should be present");
            assert_eq!(
                codex_worker.agent_session_id.as_deref(),
                Some("codex-worker")
            );
        });
    }

    #[test]
    fn end_session_requires_leader() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s2")).expect("start");
            let joined = join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
            )
            .expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .expect("worker id")
                .clone();
            let result = end_session(&state.session_id, &worker_id, project);
            assert!(result.is_err());
        });
    }

    #[test]
    fn task_lifecycle() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s3")).expect("start");
            let leader_id = state.leader_id.expect("leader id");

            let item = create_task(
                "s3",
                "fix bug",
                Some("details"),
                TaskSeverity::High,
                &leader_id,
                project,
            )
            .expect("task");
            assert_eq!(item.status, TaskStatus::Open);

            let tasks = list_tasks("s3", None, project).expect("list");
            assert_eq!(tasks.len(), 1);

            update_task(
                "s3",
                &item.task_id,
                TaskStatus::Done,
                Some("fixed"),
                &leader_id,
                project,
            )
            .expect("update");

            let tasks = list_tasks("s3", Some(TaskStatus::Done), project).expect("done");
            assert_eq!(tasks.len(), 1);
            assert_eq!(tasks[0].notes.len(), 1);
            assert!(tasks[0].completed_at.is_some());
        });
    }

    #[test]
    fn remove_agent_returns_tasks() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s4")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                join_session("s4", SessionRole::Worker, "codex", &[], None, project).expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .expect("worker id")
                .clone();

            let task = create_task(
                "s4",
                "task1",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("task");
            assign_task("s4", &task.task_id, &worker_id, &leader_id, project).expect("assign");
            remove_agent("s4", &worker_id, &leader_id, project).expect("remove");

            let tasks = list_tasks("s4", Some(TaskStatus::Open), project).expect("open");
            assert_eq!(tasks.len(), 1);
            assert!(tasks[0].assigned_to.is_none());
        });
    }

    #[test]
    fn removed_agent_loses_mutation_permissions() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("perm")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined = join_session("perm", SessionRole::Worker, "codex", &[], None, project)
                .expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            let task = create_task(
                "perm",
                "task1",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("task");

            remove_agent("perm", &worker_id, &leader_id, project).expect("remove");

            let error = update_task(
                "perm",
                &task.task_id,
                TaskStatus::Done,
                None,
                &worker_id,
                project,
            )
            .expect_err("permission");
            assert_eq!(error.code(), "KSRCLI091");
        });
    }

    #[test]
    fn assign_role_rejects_leader_changes() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("roles")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined = join_session("roles", SessionRole::Worker, "codex", &[], None, project)
                .expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            let error = assign_role(
                "roles",
                &worker_id,
                SessionRole::Leader,
                None,
                &leader_id,
                project,
            )
            .expect_err("role");
            assert_eq!(error.code(), "KSRCLI092");
        });
    }

    #[test]
    fn assign_task_requires_active_assignee() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("assign")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined = join_session("assign", SessionRole::Worker, "codex", &[], None, project)
                .expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            let task = create_task(
                "assign",
                "task1",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("task");

            remove_agent("assign", &worker_id, &leader_id, project).expect("remove");

            let error = assign_task("assign", &task.task_id, &worker_id, &leader_id, project)
                .expect_err("assign");
            assert_eq!(error.code(), "KSRCLI092");
        });
    }

    #[test]
    fn transfer_leader_requires_active_target() {
        with_temp_project(|project| {
            let state =
                start_session("test", project, Some("claude"), Some("transfer")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined = join_session("transfer", SessionRole::Worker, "codex", &[], None, project)
                .expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            remove_agent("transfer", &worker_id, &leader_id, project).expect("remove");

            let error = transfer_leader("transfer", &worker_id, None, &leader_id, project)
                .expect_err("transfer");
            assert_eq!(error.code(), "KSRCLI092");
        });
    }

    #[test]
    fn observer_transfer_leader_creates_pending_request() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("transfer-pending"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let observer =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                    join_session(
                        "transfer-pending",
                        SessionRole::Observer,
                        "codex",
                        &[],
                        Some("observer"),
                        project,
                    )
                    .expect("join observer")
                });
            let observer_id = observer
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("observer id")
                .clone();

            transfer_leader(
                "transfer-pending",
                &observer_id,
                Some("leader is overloaded"),
                &observer_id,
                project,
            )
            .expect("request transfer");

            let updated = session_status("transfer-pending", project).expect("status");
            assert_eq!(updated.leader_id.as_deref(), Some(leader_id.as_str()));
            let request = updated
                .pending_leader_transfer
                .as_ref()
                .expect("pending request");
            assert_eq!(request.requested_by, observer_id);
            assert_eq!(request.current_leader_id, leader_id);
            assert_eq!(request.new_leader_id, request.requested_by);
        });
    }

    #[test]
    fn current_leader_confirms_pending_transfer() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("transfer-confirm"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let observer =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                    join_session(
                        "transfer-confirm",
                        SessionRole::Observer,
                        "codex",
                        &[],
                        Some("observer"),
                        project,
                    )
                    .expect("join observer")
                });
            let observer_id = observer
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("observer id")
                .clone();

            transfer_leader(
                "transfer-confirm",
                &observer_id,
                Some("codex is ready"),
                &observer_id,
                project,
            )
            .expect("request transfer");
            transfer_leader(
                "transfer-confirm",
                &observer_id,
                Some("approved"),
                &leader_id,
                project,
            )
            .expect("confirm transfer");

            let updated = session_status("transfer-confirm", project).expect("status");
            assert_eq!(updated.leader_id.as_deref(), Some(observer_id.as_str()));
            assert!(updated.pending_leader_transfer.is_none());

            let entries = storage::load_log_entries(project, "transfer-confirm").expect("entries");
            assert!(entries.iter().any(|entry| {
                matches!(
                    entry.transition,
                    SessionTransition::LeaderTransferRequested { .. }
                )
            }));
            assert!(entries.iter().any(|entry| {
                matches!(
                    entry.transition,
                    SessionTransition::LeaderTransferConfirmed { .. }
                )
            }));
            assert!(entries.iter().any(|entry| {
                matches!(
                    entry.transition,
                    SessionTransition::LeaderTransferred { .. }
                )
            }));
        });
    }

    #[test]
    fn observer_transfer_leader_succeeds_when_current_leader_is_unresponsive() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("transfer-timeout"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let observer =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                    join_session(
                        "transfer-timeout",
                        SessionRole::Observer,
                        "codex",
                        &[],
                        Some("observer"),
                        project,
                    )
                    .expect("join observer")
                });
            let observer_id = observer
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("observer id")
                .clone();

            storage::update_state(project, "transfer-timeout", |state| {
                let stale = (Utc::now() - Duration::seconds(600)).to_rfc3339();
                let leader = state.agents.get_mut(&leader_id).expect("leader");
                leader.last_activity_at = Some(stale.clone());
                state.last_activity_at = Some(stale);
                Ok(())
            })
            .expect("mark stale");

            transfer_leader(
                "transfer-timeout",
                &observer_id,
                Some("leader timed out"),
                &observer_id,
                project,
            )
            .expect("forced transfer");

            let updated = session_status("transfer-timeout", project).expect("status");
            assert_eq!(updated.leader_id.as_deref(), Some(observer_id.as_str()));
            assert!(updated.pending_leader_transfer.is_none());
        });
    }

    #[test]
    fn list_sessions_returns_all_when_requested() {
        with_temp_project(|project| {
            let first =
                start_session("goal1", project, Some("claude"), Some("ls1")).expect("start one");
            start_session("goal2", project, Some("codex"), Some("ls2")).expect("start two");
            end_session("ls1", first.leader_id.as_deref().expect("leader"), project).expect("end");

            let active_only = list_sessions(project, false).expect("active list");
            let all_sessions = list_sessions(project, true).expect("all list");
            assert_eq!(active_only.len(), 1);
            assert_eq!(all_sessions.len(), 2);
        });
    }

    #[test]
    fn checkpoint_record_updates_task_summary_and_log() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s5")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let task = create_task(
                "s5",
                "watch daemon",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("task");

            let checkpoint = record_task_checkpoint(
                "s5",
                &task.task_id,
                &leader_id,
                "watcher attached",
                35,
                project,
            )
            .expect("checkpoint");

            let updated = session_status("s5", project).expect("status");
            let stored_task = updated.tasks.get(&task.task_id).expect("stored task");
            assert_eq!(
                stored_task
                    .checkpoint_summary
                    .as_ref()
                    .expect("summary")
                    .progress,
                35
            );

            let checkpoints =
                storage::load_task_checkpoints(project, "s5", &task.task_id).expect("checkpoints");
            assert_eq!(checkpoints.len(), 1);
            assert_eq!(checkpoints[0].checkpoint_id, checkpoint.checkpoint_id);
        });
    }

    #[test]
    fn send_signal_lists_pending_signal_for_target_agent() {
        with_temp_project(|project| {
            let state = start_session("test", project, Some("claude"), Some("s6")).expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                join_session("s6", SessionRole::Worker, "codex", &[], None, project).expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .expect("worker id")
                .clone();

            send_signal(
                "s6",
                &worker_id,
                "inject_context",
                "new task queued",
                Some("review task-1"),
                &leader_id,
                project,
            )
            .expect("signal");

            let signals = list_signals("s6", Some(&worker_id), project).expect("signals");
            assert_eq!(signals.len(), 1);
            assert_eq!(signals[0].status, SessionSignalStatus::Pending);
            assert_eq!(signals[0].runtime, "codex");
            assert_eq!(signals[0].signal.command, "inject_context");
        });
    }

    #[test]
    fn send_signal_denies_worker_actor() {
        with_temp_project(|project| {
            start_session("test", project, Some("claude"), Some("s7")).expect("start");
            let joined =
                join_session("s7", SessionRole::Worker, "codex", &[], None, project).expect("join");
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .expect("worker id")
                .clone();

            let error = send_signal(
                "s7",
                &worker_id,
                "inject_context",
                "workers should not send signals",
                None,
                &worker_id,
                project,
            )
            .expect_err("permission denied");

            assert_eq!(error.code(), "KSRCLI091");
        });
    }
}
