use std::path::Path;

use harness_daemon_client::DaemonClient;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_kernel::io::validate_safe_segment;
use harness_session::service::{
    TaskSpec, assign_task_local, create_task_with_source_local, daemon_client_error,
    delete_task_local, drop_task_local, generate_checkpoint_id, record_task_checkpoint_local,
    update_task_local,
};
use harness_session::types::{TaskCheckpoint, TaskQueuePolicy, TaskStatus, WorkItem};
use harness_session::wire;
use harness_workspace::workspace::utc_now;
use tokio::runtime::Handle;

/// Build the `/v1/sessions/{id}/tasks/{id}/{action}` URL shared by
/// `assign_task`, `drop_task`, `update_task`, and `record_task_checkpoint`.
/// `create_task_with_source` and `delete_task` hit their own action-less
/// paths, so neither goes through this helper.
fn task_action_url(session_id: &str, task_id: &str, action: &str) -> Result<String, CliError> {
    validate_safe_segment(session_id)?;
    validate_safe_segment(task_id)?;
    Ok(format!(
        "/v1/sessions/{session_id}/tasks/{task_id}/{action}"
    ))
}

/// Create a task with explicit source metadata, dialing a live daemon first
/// when one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
pub fn create_task_with_source(
    session_id: &str,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        let request = wire::TaskCreateRequest {
            actor: actor_id.to_string(),
            title: spec.title.to_string(),
            context: spec.context.map(ToString::to_string),
            severity: spec.severity,
            suggested_fix: spec.suggested_fix.map(ToString::to_string),
        };
        let detail: wire::SessionDetail = client
            .post(&format!("/v1/sessions/{session_id}/task"), &request)
            .map_err(|error| daemon_client_error("create task", &error))?;
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

    create_task_with_source_local(session_id, spec, actor_id, project_dir)
}

/// Assign a work item to an agent (leader only), dialing a live daemon first
/// when one is reachable.
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
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        let request = wire::TaskAssignRequest {
            actor: actor_id.to_string(),
            agent_id: agent_id.to_string(),
        };
        let url = task_action_url(session_id, task_id, "assign")?;
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("assign task", &error))?;
        return Ok(());
    }

    assign_task_local(session_id, task_id, agent_id, actor_id, project_dir)
}

/// Drop a work item onto a session target, dialing a live daemon first when
/// one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target is invalid,
/// or signal delivery setup fails for an immediately-started task.
pub fn drop_task(
    session_id: &str,
    task_id: &str,
    target: &wire::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        let request = wire::TaskDropRequest {
            actor: actor_id.to_string(),
            target: target.clone(),
            queue_policy,
            reason: None,
        };
        let url = task_action_url(session_id, task_id, "drop")?;
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("drop task", &error))?;
        return Ok(());
    }

    drop_task_local(
        session_id,
        task_id,
        target,
        queue_policy,
        actor_id,
        project_dir,
    )
}

/// Delete a work item from active task views while preserving history,
/// dialing a live daemon first when one is reachable.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn delete_task(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        validate_safe_segment(session_id)?;
        validate_safe_segment(task_id)?;
        let request = wire::TaskDeleteRequest {
            actor: actor_id.to_string(),
        };
        let url = format!("/v1/sessions/{session_id}/tasks/{task_id}");
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("delete task", &error))?;
        return Ok(());
    }

    delete_task_local(session_id, task_id, actor_id, project_dir)
}

/// Update a work item's status, dialing a live daemon first when one is
/// reachable.
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
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        let request = wire::TaskUpdateRequest {
            actor: actor_id.to_string(),
            status,
            note: note.map(ToString::to_string),
        };
        let url = task_action_url(session_id, task_id, "status")?;
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("update task", &error))?;
        return Ok(());
    }

    update_task_local(session_id, task_id, status, note, actor_id, project_dir)
}

/// Record an append-only task checkpoint, dialing a live daemon first when
/// one is reachable.
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
    if Handle::try_current().is_err()
        && let Some(client) = DaemonClient::try_connect()
    {
        let request = wire::TaskCheckpointRequest {
            actor: actor_id.to_string(),
            summary: summary.to_string(),
            progress,
        };
        let url = task_action_url(session_id, task_id, "checkpoint")?;
        let _: wire::SessionDetail = client
            .post(&url, &request)
            .map_err(|error| daemon_client_error("checkpoint task", &error))?;
        return Ok(TaskCheckpoint {
            checkpoint_id: generate_checkpoint_id(task_id),
            task_id: task_id.to_string(),
            recorded_at: utc_now(),
            actor_id: Some(actor_id.to_string()),
            summary: summary.to_string(),
            progress,
        });
    }

    record_task_checkpoint_local(
        session_id,
        task_id,
        actor_id,
        summary,
        progress,
        project_dir,
    )
}
