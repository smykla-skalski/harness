use std::collections::BTreeMap;
use std::env;
use std::fmt;
use std::path::{Path, PathBuf};
use std::slice;

use chrono::{Duration, Utc};
use serde_json::Value;

use crate::agents::runtime;
use crate::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
    acknowledge_signal as write_signal_ack, read_acknowledged_signals, read_acknowledgments,
    read_pending_signals, signal_matches_session,
};
use crate::agents::service as agents_service;
use crate::daemon::client::DaemonClient;
use crate::daemon::index as daemon_index;
use crate::daemon::ordering::sort_session_tasks;
use crate::daemon::protocol;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::workspace::utc_now;

use super::roles::{SessionAction, is_permitted};
use super::storage;
use super::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, PendingLeaderTransfer, SessionMetrics,
    SessionRole, SessionSignalRecord, SessionSignalStatus, SessionState, SessionStatus,
    SessionTransition, TaskCheckpoint, TaskCheckpointSummary, TaskNote, TaskQueuePolicy,
    TaskSeverity, TaskSource, TaskStatus, WorkItem,
};

const DEFAULT_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS: i64 = 300;
const LEAVE_SESSION_SIGNAL_COMMAND: &str = "abort";
const END_SESSION_SIGNAL_MESSAGE: &str =
    "This harness session has ended. Stop current work and leave the harness session.";
const REMOVE_AGENT_SIGNAL_MESSAGE: &str = "You have been removed from this harness session. Stop current work and leave the harness session.";
const END_SESSION_SIGNAL_ACTION_HINT: &str = "harness:session:end";
const REMOVE_AGENT_SIGNAL_ACTION_HINT: &str = "harness:session:remove-agent";
const START_TASK_SIGNAL_COMMAND: &str = "request_action";

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

#[derive(Debug, Clone)]
pub(crate) struct LeaveSignalRecord {
    pub(crate) runtime: String,
    pub(crate) agent_id: String,
    pub(crate) signal_session_id: String,
    pub(crate) signal: Signal,
}

#[derive(Debug, Clone)]
pub(crate) enum TaskDropEffect {
    Started(Box<TaskStartSignalRecord>),
    Queued { task_id: String, agent_id: String },
}

#[derive(Debug, Clone)]
pub(crate) struct TaskStartSignalRecord {
    pub(crate) task_id: String,
    pub(crate) runtime: String,
    pub(crate) agent_id: String,
    pub(crate) signal_session_id: String,
    pub(crate) signal: Signal,
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
    title: &str,
    project_dir: &Path,
    runtime_name: Option<&str>,
    session_id: Option<&str>,
) -> Result<SessionState, CliError> {
    let runtime_name = runtime_name.ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(
            "session start requires --runtime for leader session tracking".to_string(),
        ))
    })?;
    ensure_known_runtime(runtime_name, "session start requires a known runtime")?;

    if let Some(client) = DaemonClient::try_connect() {
        return client.start_session(&protocol::SessionStartRequest {
            title: title.to_string(),
            context: context.to_string(),
            runtime: runtime_name.to_string(),
            session_id: session_id.map(ToString::to_string),
            project_dir: project_dir.to_string_lossy().into_owned(),
        });
    }

    let now = utc_now();
    let leader_runtime = resolve_registered_runtime(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "session start requires a known runtime, got '{runtime_name}'"
        )))
    })?;
    let leader_agent_session_id =
        agents_service::resolve_known_session_id(leader_runtime, project_dir, None)?;
    let state = create_initial_session(
        context,
        title,
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
        log_session_started(title, context),
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
    ensure_known_runtime(runtime_name, "agent join requires a known runtime")?;
    if let Some(client) = DaemonClient::try_connect() {
        return client.join_session(
            session_id,
            &protocol::SessionJoinRequest {
                runtime: runtime_name.to_string(),
                role,
                capabilities: capabilities.to_vec(),
                name: name.map(ToString::to_string),
                project_dir: project_dir.to_string_lossy().into_owned(),
            },
        );
    }

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
        let agent_id = apply_join_session(
            state,
            &display_name,
            runtime_name,
            role,
            capabilities,
            agent_session_id.as_deref(),
            &now,
        )?;
        joined_agent_id = Some(agent_id);
        Ok(())
    })?;

    let agent_id = joined_agent_id.expect("join_session must record the new agent ID");
    storage::append_log_entry(
        project_dir,
        session_id,
        log_agent_joined(&agent_id, role, runtime_name),
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
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.end_session(
            session_id,
            &protocol::SessionEndRequest {
                actor: actor_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut leave_signals = Vec::new();

    storage::update_state(project_dir, session_id, |state| {
        leave_signals = prepare_end_session_leave_signals(state, actor_id, &now)?;
        write_prepared_leave_signals(project_dir, &leave_signals, "end session")?;
        apply_end_session(state, actor_id, &now)
    })?;

    append_leave_signal_logs(project_dir, session_id, actor_id, &leave_signals)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        log_session_ended(),
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
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.assign_role(
            session_id,
            agent_id,
            &protocol::RoleChangeRequest {
                actor: actor_id.to_string(),
                role,
                reason: reason.map(ToString::to_string),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut from_role = SessionRole::Worker;

    storage::update_state(project_dir, session_id, |state| {
        from_role = apply_assign_role(state, agent_id, role, actor_id, &now)?;
        Ok(())
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        log_role_changed(agent_id, from_role, role),
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
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.remove_agent(
            session_id,
            agent_id,
            &protocol::AgentRemoveRequest {
                actor: actor_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut leave_signal = None;

    storage::update_state(project_dir, session_id, |state| {
        leave_signal = prepare_remove_agent_leave_signal(state, agent_id, actor_id, &now)?;
        if let Some(ref signal) = leave_signal {
            write_prepared_leave_signals(project_dir, slice::from_ref(signal), "remove agent")?;
        }
        apply_remove_agent(state, agent_id, actor_id, &now)
    })?;

    if let Some(ref signal) = leave_signal {
        append_leave_signal_logs(project_dir, session_id, actor_id, slice::from_ref(signal))?;
    }
    storage::append_log_entry(
        project_dir,
        session_id,
        log_agent_removed(agent_id),
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
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.transfer_leader(
            session_id,
            &protocol::LeaderTransferRequest {
                actor: actor_id.to_string(),
                new_leader_id: new_leader_id.to_string(),
                reason: reason.map(ToString::to_string),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut transfer = None;

    storage::update_state(project_dir, session_id, |state| {
        transfer = Some(apply_transfer_leader(
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
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.create_task(
            session_id,
            &protocol::TaskCreateRequest {
                actor: actor_id.to_string(),
                title: spec.title.to_string(),
                context: spec.context.map(ToString::to_string),
                severity: spec.severity,
                suggested_fix: spec.suggested_fix.map(ToString::to_string),
            },
        )?;
        let created = detail.tasks.into_iter().max_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| left.updated_at.cmp(&right.updated_at))
                .then_with(|| left.task_id.cmp(&right.task_id))
        });
        return created.ok_or_else(|| {
            CliErrorKind::workflow_io("daemon created task but returned empty task list").into()
        });
    }

    let now = utc_now();
    let mut created_item = None;

    storage::update_state(project_dir, session_id, |state| {
        created_item = Some(apply_create_task(state, spec, actor_id, &now)?);
        Ok(())
    })?;

    let item = created_item.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task creation did not persist state".to_string(),
        ))
    })?;
    storage::append_log_entry(
        project_dir,
        session_id,
        log_task_created(spec, &item),
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
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.assign_task(
            session_id,
            task_id,
            &protocol::TaskAssignRequest {
                actor: actor_id.to_string(),
                agent_id: agent_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();

    storage::update_state(project_dir, session_id, |state| {
        apply_assign_task(state, task_id, agent_id, actor_id, &now)
    })?;

    storage::append_log_entry(
        project_dir,
        session_id,
        log_task_assigned(task_id, agent_id),
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// Drop a work item onto a session target.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target is invalid,
/// or signal delivery setup fails for an immediately-started task.
pub fn drop_task(
    session_id: &str,
    task_id: &str,
    target: &protocol::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.drop_task(
            session_id,
            task_id,
            &protocol::TaskDropRequest {
                actor: actor_id.to_string(),
                target: target.clone(),
                queue_policy,
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut effects = Vec::new();
    storage::update_state(project_dir, session_id, |state| {
        effects = apply_drop_task(state, task_id, target, queue_policy, actor_id, &now)?;
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;
    Ok(())
}

/// Change a queued task's reassignment policy.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or queue promotion signal
/// delivery fails.
pub fn update_task_queue_policy(
    session_id: &str,
    task_id: &str,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut effects = Vec::new();
    storage::update_state(project_dir, session_id, |state| {
        effects = apply_update_task_queue_policy(state, task_id, queue_policy, actor_id, &now)?;
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;
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
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        let mut items: Vec<WorkItem> = detail
            .tasks
            .into_iter()
            .filter(|task| status_filter.is_none_or(|status| task.status == status))
            .collect();
        sort_session_tasks(&mut items);
        return Ok(items);
    }

    let state = load_state_or_err(session_id, project_dir)?;
    let mut items: Vec<WorkItem> = state
        .tasks
        .into_values()
        .filter(|task| status_filter.is_none_or(|status| task.status == status))
        .collect();
    sort_session_tasks(&mut items);
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
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.update_task(
            session_id,
            task_id,
            &protocol::TaskUpdateRequest {
                actor: actor_id.to_string(),
                status,
                note: note.map(ToString::to_string),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let mut from_status = TaskStatus::Open;
    let mut effects = Vec::new();

    storage::update_state(project_dir, session_id, |state| {
        from_status = apply_update_task(state, task_id, status, note, actor_id, &now)?;
        effects = apply_advance_queued_tasks(state, actor_id, &now)?;
        refresh_session(state, &now);
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        log_task_status_changed(task_id, from_status, status),
        Some(actor_id),
        None,
    )?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;

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

    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.checkpoint_task(
            session_id,
            task_id,
            &protocol::TaskCheckpointRequest {
                actor: actor_id.to_string(),
                summary: summary.to_string(),
                progress,
            },
        )?;
        return Ok(TaskCheckpoint {
            checkpoint_id: generate_checkpoint_id(task_id),
            task_id: task_id.to_string(),
            recorded_at: utc_now(),
            actor_id: Some(actor_id.to_string()),
            summary: summary.to_string(),
            progress,
        });
    }

    let now = utc_now();
    let mut checkpoint = None;

    storage::update_state(project_dir, session_id, |state| {
        checkpoint = Some(apply_record_checkpoint(
            state, task_id, actor_id, summary, progress, &now,
        )?);
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
        log_checkpoint_recorded(task_id, &checkpoint.checkpoint_id, progress),
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
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.send_signal(
            session_id,
            &protocol::SignalSendRequest {
                actor: actor_id.to_string(),
                agent_id: agent_id.to_string(),
                command: command.to_string(),
                message: message.to_string(),
                action_hint: action_hint.map(ToString::to_string),
            },
        )?;
        return detail
            .signals
            .into_iter()
            .find(|signal| signal.signal.command == command && signal.agent_id == agent_id)
            .ok_or_else(|| {
                CliErrorKind::workflow_io(
                    "daemon sent signal but returned no matching signal record",
                )
                .into()
            });
    }

    let now = utc_now();
    let mut runtime_name = String::new();
    let mut target_agent_session_id = None;

    storage::update_state(project_dir, session_id, |state| {
        let (name, session_id) = apply_send_signal_state(state, agent_id, actor_id, &now)?;
        runtime_name = name;
        target_agent_session_id = session_id;
        Ok(())
    })?;

    let runtime = runtime::runtime_for_name(&runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{runtime_name}'"
        )))
    })?;

    let signal = build_signal(
        actor_id,
        command,
        message,
        action_hint,
        session_id,
        agent_id,
        &now,
    );

    let signal_session_id = target_agent_session_id.as_deref().unwrap_or(session_id);
    runtime.write_signal(project_dir, signal_session_id, &signal)?;
    storage::append_log_entry(
        project_dir,
        session_id,
        log_signal_sent(&signal.signal_id, agent_id, command),
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

/// Cancel a pending signal by writing a rejected acknowledgment and moving the
/// signal file out of pending.
///
/// Signal delivery is passive: the runtime's agent hook cycles read pending
/// signals and write acks. When a user cancels from the monitor, we write the
/// rejected ack directly and move the file so the next hook cycle does not
/// deliver the signal, and the monitor shows a consistent state on its next
/// snapshot.
///
/// # Errors
/// Returns `CliError` when the session/agent cannot be resolved, the signal
/// file cannot be found, or ack persistence fails.
pub fn cancel_signal(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        client.cancel_signal(
            session_id,
            &protocol::SignalCancelRequest {
                actor: actor_id.to_string(),
                agent_id: agent_id.to_string(),
                signal_id: signal_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let state = load_state_or_err(session_id, project_dir)?;
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found in session '{session_id}'"
        )))
    })?;
    let runtime = runtime::runtime_for_name(&agent.runtime).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{}'",
            agent.runtime
        )))
    })?;

    let now = utc_now();
    let signal_session_id = agent.agent_session_id.as_deref().unwrap_or(session_id);
    let signal_dir = runtime.signal_dir(project_dir, signal_session_id);

    let pending = read_pending_signals(&signal_dir)?;
    let matched = pending.iter().any(|signal| signal.signal_id == signal_id);
    if !matched {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "signal '{signal_id}' is not pending for agent '{agent_id}'"
        ))));
    }

    let ack = SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at: now,
        result: AckResult::Rejected,
        agent: signal_session_id.to_string(),
        session_id: session_id.to_string(),
        details: Some(format!("cancelled by {actor_id}")),
    };
    write_signal_ack(&signal_dir, &ack)?;

    storage::append_log_entry(
        project_dir,
        session_id,
        log_signal_acknowledged(signal_id, agent_id, AckResult::Rejected),
        Some(actor_id),
        None,
    )?;
    Ok(())
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
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        let mut signals: Vec<SessionSignalRecord> = detail
            .signals
            .into_iter()
            .filter(|signal| agent_filter.is_none_or(|filter| signal.agent_id == filter))
            .collect();
        signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
        return Ok(signals);
    }

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
                .map(|signal_session_id| {
                    (
                        signal_session_id.clone(),
                        runtime.signal_dir(project_dir, &signal_session_id),
                    )
                })
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
    if let Some(client) = DaemonClient::try_connect() {
        return resolve_runtime_session_via_daemon(&client, runtime_name, runtime_session_id);
    }

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
    if let Some(client) = DaemonClient::try_connect() {
        return client.record_signal_ack(
            session_id,
            &protocol::SignalAckRequest {
                agent_id: agent_id.to_string(),
                signal_id: signal_id.to_string(),
                result,
                project_dir: project_dir.to_string_lossy().into_owned(),
            },
        );
    }

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
        log_signal_acknowledged(signal_id, agent_id, result),
        Some(agent_id),
        None,
    )
}

fn signal_records_for_dirs(
    runtime_name: &str,
    agent_id: &str,
    session_id: &str,
    signal_dirs: &[(String, PathBuf)],
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let mut signals_by_id = BTreeMap::new();
    let mut acknowledgments_by_id = BTreeMap::new();

    for (signal_session_id, signal_dir) in signal_dirs {
        for signal in read_pending_signals(signal_dir)? {
            signals_by_id.entry(signal.signal_id.clone()).or_insert((
                signal,
                false,
                signal_session_id.clone(),
            ));
        }
        for signal in read_acknowledged_signals(signal_dir)? {
            signals_by_id.insert(
                signal.signal_id.clone(),
                (signal, true, signal_session_id.clone()),
            );
        }
        for acknowledgment in read_acknowledgments(signal_dir)? {
            acknowledgments_by_id
                .entry(acknowledgment.signal_id.clone())
                .or_insert(acknowledgment);
        }
    }

    Ok(signals_by_id
        .into_values()
        .filter_map(|(signal, was_acknowledged, signal_session_id)| {
            let acknowledgment = acknowledgments_by_id.remove(&signal.signal_id);
            if !signal_matches_session(
                &signal,
                acknowledgment.as_ref(),
                session_id,
                agent_id,
                &signal_session_id,
            ) {
                return None;
            }
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
            Some(SessionSignalRecord {
                runtime: runtime_name.to_string(),
                agent_id: agent_id.to_string(),
                session_id: session_id.to_string(),
                status,
                signal,
                acknowledgment,
            })
        })
        .collect())
}

/// Load the current session state.
///
/// # Errors
/// Returns `CliError` if the session is not found.
pub fn session_status(session_id: &str, project_dir: &Path) -> Result<SessionState, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        let mut state = detail_to_session_state(&detail);
        state.metrics = SessionMetrics::recalculate(&state);
        return Ok(state);
    }

    let mut state = load_state_or_err(session_id, project_dir)?;
    state.metrics = SessionMetrics::recalculate(&state);
    Ok(state)
}

/// List sessions for a project.
///
/// # Errors
/// Returns `CliError` on storage failures.
pub fn list_sessions(project_dir: &Path, include_all: bool) -> Result<Vec<SessionState>, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let summaries = client.list_sessions()?;
        let mut sessions: Vec<SessionState> = summaries
            .into_iter()
            .filter(|summary| include_all || summary.status == SessionStatus::Active)
            .map(|summary| summary_to_session_state(&summary))
            .collect();
        sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        return Ok(sessions);
    }

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
    if let Some(client) = DaemonClient::try_connect() {
        let summaries = client.list_sessions()?;
        let mut sessions: Vec<SessionState> = summaries
            .into_iter()
            .filter(|summary| include_all || summary.status == SessionStatus::Active)
            .map(|summary| summary_to_session_state(&summary))
            .collect();
        sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        return Ok(sessions);
    }

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
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
        return Ok(detail
            .session
            .project_dir
            .map_or_else(|| PathBuf::from(detail.session.context_root), PathBuf::from));
    }
    let resolved = daemon_index::resolve_session(session_id)?;
    Ok(resolved
        .project
        .project_dir
        .unwrap_or(resolved.project.context_root))
}

// ---------------------------------------------------------------------------
// Extracted state-mutation functions
//
// These apply business logic to an in-memory `SessionState` without touching
// storage. Both the file-based path (`storage::update_state` closures) and the
// daemon-direct path (SQLite writes) call these same functions so the rules
// are defined once.
// ---------------------------------------------------------------------------

/// Build the initial state for a new session (leader + metadata).
pub(crate) fn build_new_session(
    context: &str,
    title: &str,
    session_id: &str,
    runtime_name: &str,
    agent_session_id: Option<&str>,
    now: &str,
) -> SessionState {
    build_initial_state(
        context,
        title,
        session_id,
        runtime_name,
        agent_session_id,
        now,
    )
}

/// Register a new agent into an existing session state. Returns the assigned
/// agent ID.
pub(crate) fn apply_join_session(
    state: &mut SessionState,
    display_name: &str,
    runtime_name: &str,
    role: SessionRole,
    capabilities: &[String],
    agent_session_id: Option<&str>,
    now: &str,
) -> Result<String, CliError> {
    require_active(state)?;
    let agent_id = next_available_agent_id(runtime_name, &state.agents);
    state.agents.insert(
        agent_id.clone(),
        AgentRegistration {
            agent_id: agent_id.clone(),
            name: display_name.to_string(),
            runtime: runtime_name.to_string(),
            role,
            capabilities: capabilities.to_vec(),
            joined_at: now.to_string(),
            updated_at: now.to_string(),
            status: AgentStatus::Active,
            agent_session_id: agent_session_id.map(ToString::to_string),
            last_activity_at: Some(now.to_string()),
            current_task_id: None,
            runtime_capabilities: runtime_capabilities(runtime_name),
        },
    );
    refresh_session(state, now);
    Ok(agent_id)
}

pub(crate) fn prepare_end_session_leave_signals(
    state: &SessionState,
    actor_id: &str,
    now: &str,
) -> Result<Vec<LeaveSignalRecord>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::EndSession)?;
    ensure_session_can_end(state)?;

    state
        .agents
        .values()
        .filter(|agent| agent.status == AgentStatus::Active)
        .map(|agent| {
            build_leave_signal_record(
                state,
                agent,
                actor_id,
                END_SESSION_SIGNAL_MESSAGE,
                END_SESSION_SIGNAL_ACTION_HINT,
                now,
                "end session",
            )
        })
        .collect()
}

pub(crate) fn prepare_remove_agent_leave_signal(
    state: &SessionState,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<Option<LeaveSignalRecord>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::RemoveAgent)?;
    require_removable_agent(state, agent_id)?;

    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if agent.status != AgentStatus::Active {
        return Ok(None);
    }

    build_leave_signal_record(
        state,
        agent,
        actor_id,
        REMOVE_AGENT_SIGNAL_MESSAGE,
        REMOVE_AGENT_SIGNAL_ACTION_HINT,
        now,
        "remove agent",
    )
    .map(Some)
}

pub(crate) fn write_prepared_leave_signals(
    project_dir: &Path,
    signals: &[LeaveSignalRecord],
    action: &str,
) -> Result<(), CliError> {
    for signal in signals {
        let runtime = runtime::runtime_for_name(&signal.runtime).ok_or_else(|| {
            leave_signal_delivery_error(
                action,
                &signal.agent_id,
                format!("unknown runtime '{}'", signal.runtime),
            )
        })?;
        runtime
            .write_signal(project_dir, &signal.signal_session_id, &signal.signal)
            .map_err(|error| leave_signal_delivery_error(action, &signal.agent_id, error))?;
    }
    Ok(())
}

pub(crate) fn write_prepared_task_start_signals(
    project_dir: &Path,
    signals: &[TaskStartSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        let runtime = runtime::runtime_for_name(&signal.runtime).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "unknown runtime '{}'",
                signal.runtime
            )))
        })?;
        runtime.write_signal(project_dir, &signal.signal_session_id, &signal.signal)?;
    }
    Ok(())
}

/// Mark a session as ended. Validates permissions and active-task constraints.
pub(crate) fn apply_end_session(
    state: &mut SessionState,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::EndSession)?;
    ensure_session_can_end(state)?;

    touch_agent(state, actor_id, now);
    for agent in state.agents.values_mut() {
        if agent.status == AgentStatus::Active {
            agent.status = AgentStatus::Disconnected;
            agent.current_task_id = None;
            agent.updated_at = now.to_string();
            agent.last_activity_at = Some(now.to_string());
        }
    }
    state.pending_leader_transfer = None;
    state.status = SessionStatus::Ended;
    state.archived_at = Some(now.to_string());
    refresh_session(state, now);
    Ok(())
}

/// Change an agent's role. Returns the previous role.
pub(crate) fn apply_assign_role(
    state: &mut SessionState,
    agent_id: &str,
    role: SessionRole,
    actor_id: &str,
    now: &str,
) -> Result<SessionRole, CliError> {
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
    let from_role = agent.role;
    agent.role = role;
    agent.updated_at = now.to_string();
    agent.last_activity_at = Some(now.to_string());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(from_role)
}

/// Remove an agent, returning its in-progress tasks to Open.
pub(crate) fn apply_remove_agent(
    state: &mut SessionState,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::RemoveAgent)?;
    require_removable_agent(state, agent_id)?;

    {
        let agent = state.agents.get_mut(agent_id).ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{agent_id}' not found"
            )))
        })?;
        agent.status = AgentStatus::Removed;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
        agent.current_task_id = None;
    }
    clear_pending_leader_transfer(state, agent_id);

    for task in state.tasks.values_mut() {
        if task.assigned_to.as_deref() == Some(agent_id) && !matches!(task.status, TaskStatus::Done)
        {
            task.status = TaskStatus::Open;
            task.assigned_to = None;
            task.queue_policy = TaskQueuePolicy::Locked;
            task.queued_at = None;
            task.updated_at = now.to_string();
            task.blocked_reason = None;
            task.completed_at = None;
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}

/// Plan and optionally apply a leader transfer. Returns the transfer plan
/// so the caller can emit the right log entries.
pub(crate) fn apply_transfer_leader(
    state: &mut SessionState,
    new_leader_id: &str,
    actor_id: &str,
    reason: Option<&str>,
    now: &str,
) -> Result<LeaderTransferPlan, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::TransferLeader)?;
    plan_leader_transfer(state, new_leader_id, actor_id, reason, now)
}

/// Create a work item. Returns the new `WorkItem`.
pub(crate) fn apply_create_task(
    state: &mut SessionState,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    now: &str,
) -> Result<WorkItem, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::CreateTask)?;

    let task_id = next_task_id(&state.tasks);
    let item = WorkItem {
        task_id: task_id.clone(),
        title: spec.title.to_string(),
        context: spec.context.map(ToString::to_string),
        severity: spec.severity,
        status: TaskStatus::Open,
        assigned_to: None,
        queue_policy: TaskQueuePolicy::Locked,
        queued_at: None,
        created_at: now.to_string(),
        updated_at: now.to_string(),
        created_by: Some(actor_id.to_string()),
        notes: Vec::new(),
        suggested_fix: spec.suggested_fix.map(ToString::to_string),
        source: spec.source,
        blocked_reason: None,
        completed_at: None,
        checkpoint_summary: None,
    };
    state.tasks.insert(task_id, item.clone());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(item)
}

/// Assign a task to an agent.
pub(crate) fn apply_assign_task(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
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
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.assigned_to = Some(agent_id.to_string());
    task.status = TaskStatus::InProgress;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.updated_at = now.to_string();
    task.blocked_reason = None;
    task.completed_at = None;

    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}

/// Drop a task onto an extensible session target. The first target action is
/// worker assignment: start immediately when the worker is free, otherwise
/// queue against the selected worker.
pub(crate) fn apply_drop_task(
    state: &mut SessionState,
    task_id: &str,
    target: &protocol::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;

    match target {
        protocol::TaskDropTarget::Agent { agent_id } => {
            apply_drop_task_on_agent(state, task_id, agent_id, queue_policy, actor_id, now)
        }
    }
}

pub(crate) fn apply_update_task_queue_policy(
    state: &mut SessionState,
    task_id: &str,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.queue_policy = queue_policy;
    task.updated_at = now.to_string();
    touch_agent(state, actor_id, now);
    let effects = apply_advance_queued_tasks(state, actor_id, now)?;
    refresh_session(state, now);
    Ok(effects)
}

pub(crate) fn apply_advance_queued_tasks(
    state: &mut SessionState,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    let mut effects = Vec::new();
    let mut free_workers = free_worker_ids(state);
    free_workers.sort_unstable();

    for worker_id in free_workers.clone() {
        if start_next_locked_task_for_worker(state, &worker_id, actor_id, now, &mut effects)? {
            free_workers.retain(|candidate| candidate != &worker_id);
        }
    }

    let mut reassignable_tasks: Vec<_> = state
        .tasks
        .values()
        .filter(|task| {
            task.status == TaskStatus::Open
                && task.queued_at.is_some()
                && task.assigned_to.is_some()
                && task.queue_policy == TaskQueuePolicy::ReassignWhenFree
        })
        .map(|task| {
            (
                task.queued_at.clone().unwrap_or_default(),
                task.task_id.clone(),
            )
        })
        .collect();
    reassignable_tasks.sort_unstable();

    for (_, task_id) in reassignable_tasks {
        let Some(worker_id) = free_workers.first().cloned() else {
            break;
        };
        start_task_for_agent(state, &task_id, &worker_id, actor_id, now, &mut effects)?;
        free_workers.remove(0);
    }

    Ok(effects)
}

/// Update a task's status. Returns the previous status.
pub(crate) fn apply_update_task(
    state: &mut SessionState,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    now: &str,
) -> Result<TaskStatus, CliError> {
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

    let from_status = task.status;
    task.status = status;
    if status != TaskStatus::Open {
        task.queued_at = None;
    }
    task.updated_at = now.to_string();
    if let Some(text) = note {
        task.notes.push(TaskNote {
            timestamp: now.to_string(),
            agent_id: Some(actor_id.to_string()),
            text: text.to_string(),
        });
    }

    match status {
        TaskStatus::Done => {
            task.completed_at = Some(now.to_string());
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
                agent.updated_at = now.to_string();
                agent.last_activity_at = Some(now.to_string());
            }
        } else {
            clear_agent_current_task(state, assigned_to, task_id, now);
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(from_status)
}

/// Record a task checkpoint in state. Returns the `TaskCheckpoint`.
pub(crate) fn apply_record_checkpoint(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    summary: &str,
    progress: u8,
    now: &str,
) -> Result<TaskCheckpoint, CliError> {
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
        recorded_at: now.to_string(),
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
    task.queued_at = None;
    task.updated_at = now.to_string();
    task.checkpoint_summary = Some(TaskCheckpointSummary::from(&created));

    if let Some(assigned_to) = assigned_to.as_deref()
        && let Some(agent) = state.agents.get_mut(assigned_to)
    {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(created)
}

/// Validate and extract signal target info from state. Returns
/// `(runtime_name, target_agent_session_id)`.
pub(crate) fn apply_send_signal_state(
    state: &mut SessionState,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(String, Option<String>), CliError> {
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

    let runtime_name = target_agent.runtime.clone();
    let target_agent_session_id = target_agent.agent_session_id.clone();
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok((runtime_name, target_agent_session_id))
}

/// Build a signal payload without writing it to disk. Used by the daemon
/// handler which writes to `SQLite` first, then writes the signal file.
pub(crate) fn build_signal(
    actor_id: &str,
    command: &str,
    message: &str,
    action_hint: Option<&str>,
    session_id: &str,
    agent_id: &str,
    now: &str,
) -> Signal {
    Signal {
        signal_id: generate_signal_id(),
        version: 1,
        created_at: now.to_string(),
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
            idempotency_key: Some(format!(
                "{}:{}:{}",
                session_id,
                agent_id,
                action_hint.unwrap_or(command)
            )),
        },
    }
}

// ---------------------------------------------------------------------------
// Log-entry builders (shared between file and daemon paths)
// ---------------------------------------------------------------------------

pub(crate) fn log_session_started(title: &str, context: &str) -> SessionTransition {
    SessionTransition::SessionStarted {
        title: title.to_string(),
        context: context.to_string(),
    }
}

pub(crate) fn log_agent_joined(
    agent_id: &str,
    role: SessionRole,
    runtime: &str,
) -> SessionTransition {
    SessionTransition::AgentJoined {
        agent_id: agent_id.to_string(),
        role,
        runtime: runtime.to_string(),
    }
}

pub(crate) fn log_session_ended() -> SessionTransition {
    SessionTransition::SessionEnded
}

pub(crate) fn log_role_changed(
    agent_id: &str,
    from: SessionRole,
    to: SessionRole,
) -> SessionTransition {
    SessionTransition::RoleChanged {
        agent_id: agent_id.to_string(),
        from,
        to,
    }
}

pub(crate) fn log_agent_removed(agent_id: &str) -> SessionTransition {
    SessionTransition::AgentRemoved {
        agent_id: agent_id.to_string(),
    }
}

pub(crate) fn log_task_created(spec: &TaskSpec<'_>, item: &WorkItem) -> SessionTransition {
    if spec.source == TaskSource::Observe {
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
    }
}

pub(crate) fn log_task_assigned(task_id: &str, agent_id: &str) -> SessionTransition {
    SessionTransition::TaskAssigned {
        task_id: task_id.to_string(),
        agent_id: agent_id.to_string(),
    }
}

pub(crate) fn log_task_queued(task_id: &str, agent_id: &str) -> SessionTransition {
    SessionTransition::TaskQueued {
        task_id: task_id.to_string(),
        agent_id: agent_id.to_string(),
    }
}

pub(crate) fn log_task_status_changed(
    task_id: &str,
    from: TaskStatus,
    to: TaskStatus,
) -> SessionTransition {
    SessionTransition::TaskStatusChanged {
        task_id: task_id.to_string(),
        from,
        to,
    }
}

pub(crate) fn log_checkpoint_recorded(
    task_id: &str,
    checkpoint_id: &str,
    progress: u8,
) -> SessionTransition {
    SessionTransition::TaskCheckpointRecorded {
        task_id: task_id.to_string(),
        checkpoint_id: checkpoint_id.to_string(),
        progress,
    }
}

pub(crate) fn log_signal_sent(signal_id: &str, agent_id: &str, command: &str) -> SessionTransition {
    SessionTransition::SignalSent {
        signal_id: signal_id.to_string(),
        agent_id: agent_id.to_string(),
        command: command.to_string(),
    }
}

pub(crate) fn log_signal_acknowledged(
    signal_id: &str,
    agent_id: &str,
    result: AckResult,
) -> SessionTransition {
    SessionTransition::SignalAcknowledged {
        signal_id: signal_id.to_string(),
        agent_id: agent_id.to_string(),
        result,
    }
}

fn append_leave_signal_logs(
    project_dir: &Path,
    session_id: &str,
    actor_id: &str,
    signals: &[LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        storage::append_log_entry(
            project_dir,
            session_id,
            log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            Some(actor_id),
            None,
        )?;
    }
    Ok(())
}

fn append_task_drop_effect_logs(
    project_dir: &Path,
    session_id: &str,
    actor_id: &str,
    effects: &[TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            TaskDropEffect::Started(signal) => {
                storage::append_log_entry(
                    project_dir,
                    session_id,
                    log_task_assigned(&signal.task_id, &signal.agent_id),
                    Some(actor_id),
                    None,
                )?;
                storage::append_log_entry(
                    project_dir,
                    session_id,
                    log_signal_sent(
                        &signal.signal.signal_id,
                        &signal.agent_id,
                        &signal.signal.command,
                    ),
                    Some(actor_id),
                    None,
                )?;
            }
            TaskDropEffect::Queued { task_id, agent_id } => {
                storage::append_log_entry(
                    project_dir,
                    session_id,
                    log_task_queued(task_id, agent_id),
                    Some(actor_id),
                    None,
                )?;
            }
        }
    }
    Ok(())
}

fn started_task_signals(effects: &[TaskDropEffect]) -> Vec<TaskStartSignalRecord> {
    effects
        .iter()
        .filter_map(|effect| match effect {
            TaskDropEffect::Started(signal) => Some(signal.as_ref().clone()),
            TaskDropEffect::Queued { .. } => None,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Daemon response conversions
// ---------------------------------------------------------------------------

/// Reconstruct a `SessionState` from a daemon `SessionDetail` response.
fn detail_to_session_state(detail: &protocol::SessionDetail) -> SessionState {
    let agents = detail
        .agents
        .iter()
        .map(|agent| (agent.agent_id.clone(), agent.clone()))
        .collect();
    let tasks = detail
        .tasks
        .iter()
        .map(|task| (task.task_id.clone(), task.clone()))
        .collect();
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: detail.session.session_id.clone(),
        title: detail.session.title.clone(),
        context: detail.session.context.clone(),
        status: detail.session.status,
        created_at: detail.session.created_at.clone(),
        updated_at: detail.session.updated_at.clone(),
        agents,
        tasks,
        leader_id: detail.session.leader_id.clone(),
        archived_at: None,
        last_activity_at: detail.session.last_activity_at.clone(),
        observe_id: detail.session.observe_id.clone(),
        pending_leader_transfer: detail.session.pending_leader_transfer.clone(),
        metrics: detail.session.metrics.clone(),
    }
}

/// Reconstruct a minimal `SessionState` from a daemon `SessionSummary`.
///
/// The summary doesn't contain agents or tasks - only the session-level
/// fields and metrics. This is sufficient for list display.
fn summary_to_session_state(summary: &protocol::SessionSummary) -> SessionState {
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: summary.session_id.clone(),
        title: summary.title.clone(),
        context: summary.context.clone(),
        status: summary.status,
        created_at: summary.created_at.clone(),
        updated_at: summary.updated_at.clone(),
        agents: BTreeMap::new(),
        tasks: BTreeMap::new(),
        leader_id: summary.leader_id.clone(),
        archived_at: None,
        last_activity_at: summary.last_activity_at.clone(),
        observe_id: summary.observe_id.clone(),
        pending_leader_transfer: summary.pending_leader_transfer.clone(),
        metrics: summary.metrics.clone(),
    }
}

fn resolve_runtime_session_via_daemon(
    client: &DaemonClient,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    let summaries = client.list_sessions()?;
    let mut matches = Vec::new();
    for summary in &summaries {
        if summary.status != SessionStatus::Active {
            continue;
        }
        let Ok(detail) = client.get_session_detail(&summary.session_id) else {
            continue;
        };
        for agent in &detail.agents {
            if agent.status != AgentStatus::Active || agent.runtime != runtime_name {
                continue;
            }
            let matches_runtime = agent.agent_session_id.as_deref() == Some(runtime_session_id)
                || (agent.agent_session_id.is_none() && summary.session_id == runtime_session_id);
            if matches_runtime {
                matches.push(ResolvedRuntimeSessionAgent {
                    orchestration_session_id: summary.session_id.clone(),
                    agent_id: agent.agent_id.clone(),
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

fn create_initial_session(
    context: &str,
    title: &str,
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
        let candidate = build_initial_state(
            context,
            title,
            &session_id,
            runtime_name,
            agent_session_id,
            now,
        );
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
        let candidate = build_initial_state(
            context,
            title,
            &session_id,
            runtime_name,
            agent_session_id,
            now,
        );
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

fn ensure_session_can_end(state: &SessionState) -> Result<(), CliError> {
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
    Ok(())
}

fn require_removable_agent(state: &SessionState, agent_id: &str) -> Result<(), CliError> {
    if state.leader_id.as_deref() == Some(agent_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "cannot remove current leader '{agent_id}'; transfer leadership first"
        ))
        .into());
    }
    if !state.agents.contains_key(agent_id) {
        return Err(
            CliErrorKind::session_agent_conflict(format!("agent '{agent_id}' not found")).into(),
        );
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

fn build_leave_signal_record(
    state: &SessionState,
    agent: &AgentRegistration,
    actor_id: &str,
    message: &str,
    action_hint: &str,
    now: &str,
    action: &str,
) -> Result<LeaveSignalRecord, CliError> {
    if runtime::runtime_for_name(&agent.runtime).is_none() {
        return Err(leave_signal_delivery_error(
            action,
            &agent.agent_id,
            format!("unknown runtime '{}'", agent.runtime),
        ));
    }
    let signal_session_id = agent
        .agent_session_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&state.session_id)
        .to_string();
    Ok(LeaveSignalRecord {
        runtime: agent.runtime.clone(),
        agent_id: agent.agent_id.clone(),
        signal_session_id,
        signal: build_signal(
            actor_id,
            LEAVE_SESSION_SIGNAL_COMMAND,
            message,
            Some(action_hint),
            &state.session_id,
            &agent.agent_id,
            now,
        ),
    })
}

fn leave_signal_delivery_error(
    action: &str,
    agent_id: &str,
    detail: impl fmt::Display,
) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "cannot {action}: leave signal delivery failed for agent '{agent_id}' ({detail}); session was not changed and needs attention before retry"
    ))
    .into()
}

fn build_initial_state(
    context: &str,
    title: &str,
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
        title: title.to_string(),
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

fn require_active_worker_target_agent(
    state: &SessionState,
    agent_id: &str,
) -> Result<(), CliError> {
    require_active_target_agent(state, agent_id)?;
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if agent.role != SessionRole::Worker {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is a {:?}, not a worker",
            agent.role
        ))
        .into());
    }
    Ok(())
}

fn apply_drop_task_on_agent(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active_worker_target_agent(state, agent_id)?;

    let previous_assignee = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    if let Some(previous_assignee) = previous_assignee.as_deref()
        && previous_assignee != agent_id
    {
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let mut effects = Vec::new();
    if is_worker_free(state, agent_id) {
        start_task_for_agent(state, task_id, agent_id, actor_id, now, &mut effects)?;
    } else {
        queue_task_for_agent(state, task_id, agent_id, queue_policy, now)?;
        effects.push(TaskDropEffect::Queued {
            task_id: task_id.to_string(),
            agent_id: agent_id.to_string(),
        });
    }

    touch_agent(state, actor_id, now);
    let advanced = apply_advance_queued_tasks(state, actor_id, now)?;
    effects.extend(advanced);
    refresh_session(state, now);
    Ok(effects)
}

fn queue_task_for_agent(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    queue_policy: TaskQueuePolicy,
    now: &str,
) -> Result<(), CliError> {
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    if task.status != TaskStatus::Open {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {}, not open",
            task_status_label(task.status)
        ))
        .into());
    }
    task.assigned_to = Some(agent_id.to_string());
    task.queue_policy = queue_policy;
    task.queued_at = Some(now.to_string());
    task.updated_at = now.to_string();
    Ok(())
}

fn start_task_for_agent(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
    effects: &mut Vec<TaskDropEffect>,
) -> Result<(), CliError> {
    require_active_worker_target_agent(state, agent_id)?;
    if !is_worker_free(state, agent_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is not free"
        ))
        .into());
    }

    let previous_assignee = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    if let Some(previous_assignee) = previous_assignee.as_deref()
        && previous_assignee != agent_id
    {
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let signal = build_task_start_signal_record(state, task_id, agent_id, actor_id, now)?;
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.assigned_to = Some(agent_id.to_string());
    task.status = TaskStatus::InProgress;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();

    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    effects.push(TaskDropEffect::Started(Box::new(signal)));
    Ok(())
}

fn build_task_start_signal_record(
    state: &SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<TaskStartSignalRecord, CliError> {
    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    let message = task_start_message(task);
    let action_hint = task_start_action_hint(task_id);
    let signal = build_signal(
        actor_id,
        START_TASK_SIGNAL_COMMAND,
        &message,
        Some(&action_hint),
        &state.session_id,
        agent_id,
        now,
    );
    Ok(TaskStartSignalRecord {
        task_id: task_id.to_string(),
        runtime: agent.runtime.clone(),
        agent_id: agent_id.to_string(),
        signal_session_id: agent
            .agent_session_id
            .clone()
            .unwrap_or_else(|| state.session_id.clone()),
        signal,
    })
}

fn task_start_message(task: &WorkItem) -> String {
    let mut message = format!("Start work on task {}: {}", task.task_id, task.title);
    if let Some(context) = task.context.as_deref() {
        message.push_str("\n\nContext:\n");
        message.push_str(context);
    }
    if let Some(suggested_fix) = task.suggested_fix.as_deref() {
        message.push_str("\n\nSuggested fix:\n");
        message.push_str(suggested_fix);
    }
    message
}

fn task_start_action_hint(task_id: &str) -> String {
    format!("task:{task_id}")
}

fn start_next_locked_task_for_worker(
    state: &mut SessionState,
    worker_id: &str,
    actor_id: &str,
    now: &str,
    effects: &mut Vec<TaskDropEffect>,
) -> Result<bool, CliError> {
    let mut queued_tasks: Vec<_> = state
        .tasks
        .values()
        .filter(|task| {
            task.status == TaskStatus::Open
                && task.assigned_to.as_deref() == Some(worker_id)
                && task.queued_at.is_some()
        })
        .map(|task| {
            (
                task.queue_policy,
                task.queued_at.clone().unwrap_or_default(),
                task.task_id.clone(),
            )
        })
        .collect();
    queued_tasks.sort_unstable();
    let Some((TaskQueuePolicy::Locked, _, task_id)) = queued_tasks.first().cloned() else {
        return Ok(false);
    };
    start_task_for_agent(state, &task_id, worker_id, actor_id, now, effects)?;
    Ok(true)
}

fn free_worker_ids(state: &SessionState) -> Vec<String> {
    state
        .agents
        .values()
        .filter(|agent| agent.status == AgentStatus::Active && agent.role == SessionRole::Worker)
        .filter(|agent| is_worker_free(state, &agent.agent_id))
        .map(|agent| agent.agent_id.clone())
        .collect()
}

fn is_worker_free(state: &SessionState, agent_id: &str) -> bool {
    let Some(agent) = state.agents.get(agent_id) else {
        return false;
    };
    agent.status == AgentStatus::Active
        && agent.role == SessionRole::Worker
        && agent.current_task_id.is_none()
        && !state.tasks.values().any(|task| {
            task.assigned_to.as_deref() == Some(agent_id)
                && matches!(task.status, TaskStatus::InProgress | TaskStatus::InReview)
        })
}

fn resolve_registered_runtime(runtime_name: &str) -> Option<HookAgent> {
    match runtime_name {
        "claude" => Some(HookAgent::Claude),
        "copilot" => Some(HookAgent::Copilot),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

fn ensure_known_runtime(runtime_name: &str, message_prefix: &str) -> Result<(), CliError> {
    if resolve_registered_runtime(runtime_name).is_some() {
        Ok(())
    } else {
        Err(CliError::from(CliErrorKind::session_agent_conflict(
            format!("{message_prefix}, got '{runtime_name}'"),
        )))
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
pub(crate) struct LeaderTransferOutcome {
    pub(crate) old_leader: String,
    pub(crate) new_leader_id: String,
    pub(crate) confirmed_by: Option<String>,
    pub(crate) reason: Option<String>,
    pub(crate) log_request_before_transfer: bool,
}

#[derive(Debug)]
pub(crate) struct LeaderTransferPlan {
    pub(crate) pending_request: Option<PendingLeaderTransfer>,
    pub(crate) outcome: Option<LeaderTransferOutcome>,
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
        |agent_runtime| {
            let mut capabilities = agent_runtime.capabilities();
            capabilities.runtime = runtime_name.to_string();
            capabilities
        },
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

fn task_status_label(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Open => "open",
        TaskStatus::InProgress => "in progress",
        TaskStatus::InReview => "in review",
        TaskStatus::Done => "done",
        TaskStatus::Blocked => "blocked",
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
    use harness_testkit::with_isolated_harness_env;

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempfile::tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            temp_env::with_var("CLAUDE_SESSION_ID", Some("test-service"), || {
                let project = tmp.path().join("project");
                test_fn(&project);
            });
        });
    }

    #[test]
    fn start_creates_session_with_leader() {
        with_temp_project(|project| {
            let state =
                start_session("test goal", "", project, Some("claude"), None).expect("start");
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
            let state =
                start_session("test", "", project, Some("claude"), Some("s1")).expect("start");
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
            start_session("goal1", "", project, Some("claude"), Some("dup")).expect("first");
            let error =
                start_session("goal2", "", project, Some("codex"), Some("dup")).expect_err("dup");

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

            let error = start_session("goal", "", project, Some("claude"), Some(&unsafe_id))
                .expect_err("id");

            assert_eq!(error.code(), "KSRCLI059");
            assert!(!escape_dir.join("state.json").exists());
        });
    }

    #[test]
    fn start_session_requires_known_runtime() {
        with_temp_project(|project| {
            let missing_runtime = start_session("goal", "", project, None, Some("no-runtime"))
                .expect_err("runtime is required");
            assert_eq!(missing_runtime.code(), "KSRCLI092");

            let unknown_runtime = start_session("goal", "", project, Some("unknown"), Some("bad"))
                .expect_err("unknown runtime should be rejected");
            assert_eq!(unknown_runtime.code(), "KSRCLI092");
        });
    }

    #[test]
    fn start_session_accepts_vibe_and_opencode_as_distinct_runtime_names() {
        with_temp_project(|project| {
            let vibe = start_session("goal", "", project, Some("vibe"), Some("vibe-runtime"))
                .expect("vibe runtime should be accepted");
            let opencode = start_session(
                "goal",
                "",
                project,
                Some("opencode"),
                Some("opencode-runtime"),
            )
            .expect("opencode runtime should remain accepted");

            let vibe_leader = vibe
                .agents
                .values()
                .find(|agent| agent.role == SessionRole::Leader)
                .expect("vibe leader");
            assert_eq!(vibe_leader.runtime, "vibe");
            assert_eq!(vibe_leader.runtime_capabilities.runtime, "vibe");

            let opencode_leader = opencode
                .agents
                .values()
                .find(|agent| agent.role == SessionRole::Leader)
                .expect("opencode leader");
            assert_eq!(opencode_leader.runtime, "opencode");
            assert_eq!(opencode_leader.runtime_capabilities.runtime, "opencode");
        });
    }

    #[test]
    fn auto_generated_session_ids_are_unique() {
        with_temp_project(|project| {
            let first = start_session("goal1", "", project, Some("claude"), None).expect("first");
            let second = start_session("goal2", "", project, Some("codex"), None).expect("second");
            assert_ne!(first.session_id, second.session_id);
        });
    }

    #[test]
    fn join_same_runtime_keeps_distinct_agents() {
        with_temp_project(|project| {
            start_session("test", "", project, Some("claude"), Some("join-unique")).expect("start");

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
            start_session("test", "", project, Some("claude"), Some("join-runtime")).unwrap();

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
            let state =
                start_session("test", "", project, Some("claude"), Some("s2")).expect("start");
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
            let state =
                start_session("test", "", project, Some("claude"), Some("s3")).expect("start");
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
            let state =
                start_session("test", "", project, Some("claude"), Some("s4")).expect("start");
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
    fn drop_task_queues_for_busy_worker() {
        with_temp_project(|project| {
            let state = start_session("test", "", project, Some("claude"), Some("drop-queue-busy"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("busy-worker"))], || {
                join_session(
                    "drop-queue-busy",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                )
                .expect("join")
            });
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            let active = create_task(
                "drop-queue-busy",
                "active",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("active");
            assign_task(
                "drop-queue-busy",
                &active.task_id,
                &worker_id,
                &leader_id,
                project,
            )
            .expect("assign active");
            let queued = create_task(
                "drop-queue-busy",
                "queued",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("queued");

            drop_task(
                "drop-queue-busy",
                &queued.task_id,
                &protocol::TaskDropTarget::Agent {
                    agent_id: worker_id.clone(),
                },
                TaskQueuePolicy::Locked,
                &leader_id,
                project,
            )
            .expect("drop");

            let state = session_status("drop-queue-busy", project).expect("status");
            let queued_task = state.tasks.get(&queued.task_id).expect("queued task");
            assert_eq!(queued_task.status, TaskStatus::Open);
            assert_eq!(queued_task.assigned_to.as_deref(), Some(worker_id.as_str()));
            assert_eq!(queued_task.queue_policy, TaskQueuePolicy::Locked);
            assert!(queued_task.queued_at.is_some());
            let worker = state.agents.get(&worker_id).expect("worker");
            assert_eq!(
                worker.current_task_id.as_deref(),
                Some(active.task_id.as_str())
            );
        });
    }

    #[test]
    fn reassignable_drop_starts_on_free_worker() {
        with_temp_project(|project| {
            let state = start_session(
                "test",
                "",
                project,
                Some("claude"),
                Some("drop-reassign-free"),
            )
            .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let first_joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("busy-worker"))], || {
                    join_session(
                        "drop-reassign-free",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("join busy")
                });
            let busy_worker = first_joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("busy worker")
                .clone();
            let second_joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("free-worker"))], || {
                    join_session(
                        "drop-reassign-free",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("join free")
                });
            let free_worker = second_joined
                .agents
                .keys()
                .filter(|id| id.starts_with("codex-"))
                .find(|id| *id != &busy_worker)
                .expect("free worker")
                .clone();
            let active = create_task(
                "drop-reassign-free",
                "active",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("active");
            assign_task(
                "drop-reassign-free",
                &active.task_id,
                &busy_worker,
                &leader_id,
                project,
            )
            .expect("assign active");
            let task = create_task(
                "drop-reassign-free",
                "reassignable",
                Some("pick up immediately"),
                TaskSeverity::High,
                &leader_id,
                project,
            )
            .expect("task");

            drop_task(
                "drop-reassign-free",
                &task.task_id,
                &protocol::TaskDropTarget::Agent {
                    agent_id: busy_worker.clone(),
                },
                TaskQueuePolicy::ReassignWhenFree,
                &leader_id,
                project,
            )
            .expect("drop");

            let state = session_status("drop-reassign-free", project).expect("status");
            let started = state.tasks.get(&task.task_id).expect("started task");
            assert_eq!(started.status, TaskStatus::InProgress);
            assert_eq!(started.assigned_to.as_deref(), Some(free_worker.as_str()));
            assert!(started.queued_at.is_none());
            let signals =
                list_signals("drop-reassign-free", Some(&free_worker), project).expect("signals");
            assert_eq!(signals.len(), 1);
            assert_eq!(signals[0].signal.command, START_TASK_SIGNAL_COMMAND);
            let expected_action_hint = task_start_action_hint(&task.task_id);
            assert_eq!(
                signals[0].signal.payload.action_hint.as_deref(),
                Some(expected_action_hint.as_str())
            );
        });
    }

    #[test]
    fn locked_queue_advances_when_worker_finishes_current_task() {
        with_temp_project(|project| {
            let state = start_session(
                "test",
                "",
                project,
                Some("claude"),
                Some("drop-advance-locked"),
            )
            .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("advance-worker"))], || {
                    join_session(
                        "drop-advance-locked",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("join")
                });
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            let active = create_task(
                "drop-advance-locked",
                "active",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("active");
            assign_task(
                "drop-advance-locked",
                &active.task_id,
                &worker_id,
                &leader_id,
                project,
            )
            .expect("assign active");
            let queued = create_task(
                "drop-advance-locked",
                "queued",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("queued");
            drop_task(
                "drop-advance-locked",
                &queued.task_id,
                &protocol::TaskDropTarget::Agent {
                    agent_id: worker_id.clone(),
                },
                TaskQueuePolicy::Locked,
                &leader_id,
                project,
            )
            .expect("drop");

            update_task(
                "drop-advance-locked",
                &active.task_id,
                TaskStatus::Done,
                Some("done"),
                &leader_id,
                project,
            )
            .expect("finish");

            let state = session_status("drop-advance-locked", project).expect("status");
            let next = state.tasks.get(&queued.task_id).expect("next task");
            assert_eq!(next.status, TaskStatus::InProgress);
            assert_eq!(next.assigned_to.as_deref(), Some(worker_id.as_str()));
            let worker = state.agents.get(&worker_id).expect("worker");
            assert_eq!(
                worker.current_task_id.as_deref(),
                Some(queued.task_id.as_str())
            );
        });
    }

    #[test]
    fn end_session_sends_abort_leave_signal_and_disconnects_agents() {
        with_temp_project(|project| {
            let state = start_session("test", "", project, Some("claude"), Some("end-leave"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("end-leave-worker"))], || {
                    join_session(
                        "end-leave",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("join")
                });
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            end_session("end-leave", &leader_id, project).expect("end");

            let updated = session_status("end-leave", project).expect("status");
            assert_eq!(updated.status, SessionStatus::Ended);
            assert_eq!(updated.metrics.active_agent_count, 0);
            assert!(updated.pending_leader_transfer.is_none());
            assert!(updated.agents.values().all(|agent| {
                agent.status == AgentStatus::Disconnected && agent.current_task_id.is_none()
            }));

            let signals = list_signals("end-leave", None, project).expect("signals");
            assert_eq!(signals.len(), 2);
            assert!(signals.iter().all(|record| {
                record.status == SessionSignalStatus::Pending
                    && record.signal.command == LEAVE_SESSION_SIGNAL_COMMAND
                    && record
                        .signal
                        .payload
                        .message
                        .contains("leave the harness session")
                    && record.signal.payload.action_hint.as_deref()
                        == Some(END_SESSION_SIGNAL_ACTION_HINT)
            }));
            assert!(signals.iter().any(|record| record.agent_id == leader_id));
            assert!(signals.iter().any(|record| record.agent_id == worker_id));

            let entries = storage::load_log_entries(project, "end-leave").expect("entries");
            assert_eq!(
                entries
                    .iter()
                    .filter(|entry| {
                        matches!(
                            entry.transition,
                            SessionTransition::SignalSent { ref command, .. }
                                if command == LEAVE_SESSION_SIGNAL_COMMAND
                        )
                    })
                    .count(),
                2
            );
            assert!(
                entries
                    .iter()
                    .any(|entry| matches!(entry.transition, SessionTransition::SessionEnded))
            );
        });
    }

    #[test]
    fn remove_agent_sends_abort_leave_signal_to_removed_agent() {
        with_temp_project(|project| {
            let state = start_session("test", "", project, Some("claude"), Some("remove-leave"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("remove-leave-worker"))], || {
                    join_session(
                        "remove-leave",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("join")
                });
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();

            remove_agent("remove-leave", &worker_id, &leader_id, project).expect("remove");

            let updated = session_status("remove-leave", project).expect("status");
            let worker = updated.agents.get(&worker_id).expect("worker");
            assert_eq!(worker.status, AgentStatus::Removed);
            assert!(worker.current_task_id.is_none());

            let signals =
                list_signals("remove-leave", Some(&worker_id), project).expect("worker signals");
            assert_eq!(signals.len(), 1);
            assert_eq!(signals[0].status, SessionSignalStatus::Pending);
            assert_eq!(signals[0].signal.command, LEAVE_SESSION_SIGNAL_COMMAND);
            assert_eq!(
                signals[0].signal.payload.action_hint.as_deref(),
                Some(REMOVE_AGENT_SIGNAL_ACTION_HINT)
            );
            assert!(
                signals[0]
                    .signal
                    .payload
                    .message
                    .contains("leave the harness session")
            );
        });
    }

    #[test]
    fn end_session_fails_visibly_when_leave_signal_cannot_be_delivered() {
        with_temp_project(|project| {
            let state = start_session("test", "", project, Some("claude"), Some("end-leave-fail"))
                .expect("start");
            let leader_id = state.leader_id.expect("leader id");
            let joined = join_session(
                "end-leave-fail",
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
                .find(|id| id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            storage::update_state(project, "end-leave-fail", |state| {
                state.agents.get_mut(&worker_id).expect("worker").runtime = "unknown".into();
                Ok(())
            })
            .expect("mark invalid runtime");

            let error = end_session("end-leave-fail", &leader_id, project).expect_err("end fails");

            assert_eq!(error.code(), "KSRCLI092");
            let message = error.to_string();
            assert!(message.contains("leave signal delivery failed"));
            assert!(message.contains("needs attention"));
            let updated = session_status("end-leave-fail", project).expect("status");
            assert_eq!(updated.status, SessionStatus::Active);
            assert_eq!(updated.metrics.active_agent_count, 2);
            assert!(
                list_signals("end-leave-fail", None, project)
                    .expect("signals")
                    .is_empty()
            );
        });
    }

    #[test]
    fn removed_agent_loses_mutation_permissions() {
        with_temp_project(|project| {
            let state =
                start_session("test", "", project, Some("claude"), Some("perm")).expect("start");
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
                start_session("test", "", project, Some("claude"), Some("roles")).expect("start");
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
                start_session("test", "", project, Some("claude"), Some("assign")).expect("start");
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
            let state = start_session("test", "", project, Some("claude"), Some("transfer"))
                .expect("start");
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
            let state = start_session(
                "test",
                "",
                project,
                Some("claude"),
                Some("transfer-pending"),
            )
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
            let state = start_session(
                "test",
                "",
                project,
                Some("claude"),
                Some("transfer-confirm"),
            )
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
            let state = start_session(
                "test",
                "",
                project,
                Some("claude"),
                Some("transfer-timeout"),
            )
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
            let first = start_session("goal1", "", project, Some("claude"), Some("ls1"))
                .expect("start one");
            start_session("goal2", "", project, Some("codex"), Some("ls2")).expect("start two");
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
            let state =
                start_session("test", "", project, Some("claude"), Some("s5")).expect("start");
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
            let state =
                start_session("test", "", project, Some("claude"), Some("s6")).expect("start");
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
    fn list_signals_filters_shared_runtime_session_history() {
        with_temp_project(|project| {
            let session_one = start_session("test", "", project, Some("claude"), Some("s6-alpha"))
                .expect("start alpha");
            let leader_one = session_one.leader_id.expect("alpha leader id");
            let joined_one =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-shared"))], || {
                    join_session("s6-alpha", SessionRole::Worker, "codex", &[], None, project)
                        .expect("join alpha worker")
                });
            let worker_one = joined_one
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .expect("alpha worker id")
                .clone();

            let session_two = start_session("test", "", project, Some("claude"), Some("s6-beta"))
                .expect("start beta");
            let leader_two = session_two.leader_id.expect("beta leader id");
            let joined_two =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-shared"))], || {
                    join_session("s6-beta", SessionRole::Worker, "codex", &[], None, project)
                        .expect("join beta worker")
                });
            let worker_two = joined_two
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .expect("beta worker id")
                .clone();

            send_signal(
                "s6-alpha",
                &worker_one,
                "inject_context",
                "alpha task queued",
                Some("review alpha"),
                &leader_one,
                project,
            )
            .expect("alpha signal");
            send_signal(
                "s6-beta",
                &worker_two,
                "inject_context",
                "beta task queued",
                Some("review beta"),
                &leader_two,
                project,
            )
            .expect("beta signal");

            let alpha_signals =
                list_signals("s6-alpha", Some(&worker_one), project).expect("alpha signals");
            let beta_signals =
                list_signals("s6-beta", Some(&worker_two), project).expect("beta signals");

            assert_eq!(alpha_signals.len(), 1);
            assert_eq!(alpha_signals[0].signal.payload.message, "alpha task queued");
            assert_eq!(beta_signals.len(), 1);
            assert_eq!(beta_signals[0].signal.payload.message, "beta task queued");
        });
    }

    #[test]
    fn send_signal_denies_worker_actor() {
        with_temp_project(|project| {
            start_session("test", "", project, Some("claude"), Some("s7")).expect("start");
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
