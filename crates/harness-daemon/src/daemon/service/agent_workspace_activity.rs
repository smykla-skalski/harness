use std::path::PathBuf;

use harness_agents::runtime;
use harness_agents::runtime::signal::{
    AckResult, Signal, SignalAck, SignalFileState, acknowledge_signal_once,
};
use harness_daemon_db_queries::{AgentWorkspaceSignalAcknowledgment, AgentWorkspaceSignalTarget};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::{
    AgentWorkspaceActivityWindowResponse, AgentWorkspaceMemberActivityResponse,
    AgentWorkspaceSignalAckRequest, AgentWorkspaceSignalCancelRequest, AgentWorkspaceSignalRecord,
    AgentWorkspaceSignalSendRequest,
};
use harness_protocol::timeline::TimelineWindowRequest;

use super::signals::build_active_signal_prompt;
use super::sync_support::read_runtime_acknowledgments_async;
use super::wake_route::WakeDispatch;
use crate::daemon::agent_acp::AcpWakePrompt;
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::protocol::CodexSteerRequest;
use crate::daemon::state;

/// Return a workspace-owned activity window after reconciling legacy sources.
///
/// # Errors
/// Returns [`CliError`] when daemon identity, ownership, or persistence is invalid.
pub(crate) async fn get_agent_workspace_activity_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    request: &TimelineWindowRequest,
) -> Result<AgentWorkspaceActivityWindowResponse, CliError> {
    let daemon_id = prepare_activity_scope(db).await?;
    db.load_agent_workspace_activity(&daemon_id, workspace_id, request)
        .await
}

/// Return one workspace member's durable activity, transcript, and signals.
///
/// # Errors
/// Returns [`CliError`] when daemon identity, ownership, or persistence is invalid.
pub(crate) async fn get_agent_workspace_member_activity_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
) -> Result<AgentWorkspaceMemberActivityResponse, CliError> {
    let daemon_id = prepare_activity_scope(db).await?;
    let response = db
        .load_agent_workspace_member_activity(&daemon_id, workspace_id, member_id)
        .await?;
    if reconcile_runtime_acknowledgments(db, &daemon_id, &response).await {
        db.load_agent_workspace_member_activity(&daemon_id, workspace_id, member_id)
            .await
    } else {
        Ok(response)
    }
}

/// Persist and deliver a signal directly to a durable workspace member.
///
/// # Errors
/// Returns [`CliError`] when the member is not addressable or persistence/file delivery fails.
pub(crate) async fn send_agent_workspace_signal_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
    request: &AgentWorkspaceSignalSendRequest,
    dispatch: WakeDispatch<'_>,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    validate_signal_request(request)?;
    let daemon_id = prepare_activity_scope(db).await?;
    let target = db
        .load_agent_workspace_signal_target(&daemon_id, workspace_id, member_id)
        .await?;
    let now = harness_workspace::workspace::utc_now();
    let mut signal = harness_session::service::build_signal(
        &request.actor,
        request.command.trim(),
        request.message.trim(),
        request.action_hint.as_deref(),
        workspace_id,
        member_id,
        &now,
    );
    signal.delivery.idempotency_key = Some(scoped_signal_idempotency_key(
        workspace_id,
        member_id,
        &request.actor,
        &request.idempotency_key,
    ));
    let insertion = db
        .insert_agent_workspace_signal(
            &daemon_id,
            workspace_id,
            member_id,
            &target.runtime,
            &signal,
        )
        .await?;
    if !insertion.inserted && insertion.record.acknowledgment.is_some() {
        return Ok(insertion.record);
    }
    let record = insertion.record;
    let runtime_state = match write_runtime_signal(&target, &record.signal).await {
        Ok(state) => state,
        Err(delivery_error) => {
            record_failed_signal_delivery(
                db,
                &daemon_id,
                workspace_id,
                member_id,
                &record.signal.signal_id,
                &delivery_error,
            )
            .await?;
            return Err(delivery_error);
        }
    };
    match runtime_state {
        SignalFileState::Created => {
            wake_managed_agent(&target, &record.signal, dispatch);
            Ok(record)
        }
        SignalFileState::Pending => Ok(record),
        SignalFileState::Acknowledged(acknowledgment) => {
            persist_runtime_acknowledgment(db, &daemon_id, workspace_id, member_id, &acknowledgment)
                .await
        }
    }
}

/// Record an acknowledgment addressed by workspace and durable member.
///
/// # Errors
/// Returns [`CliError`] when the signal is outside the authenticated workspace scope.
pub(crate) async fn acknowledge_agent_workspace_signal_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    request: &AgentWorkspaceSignalAckRequest,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    let daemon_id = prepare_activity_scope(db).await?;
    db.acknowledge_agent_workspace_signal(
        &daemon_id,
        workspace_id,
        member_id,
        &AgentWorkspaceSignalAcknowledgment {
            signal_id: signal_id.to_string(),
            result: request.result,
            details: request.details.clone(),
            acknowledged_at: None,
        },
    )
    .await
}

/// Cancel a pending workspace signal in both the runtime file queue and durable ledger.
///
/// # Errors
/// Returns [`CliError`] when the signal is missing, outside scope, or cannot be cancelled.
pub(crate) async fn cancel_agent_workspace_signal_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    request: &AgentWorkspaceSignalCancelRequest,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    let daemon_id = prepare_activity_scope(db).await?;
    let mut activity = db
        .load_agent_workspace_member_activity(&daemon_id, workspace_id, member_id)
        .await?;
    if reconcile_runtime_acknowledgments(db, &daemon_id, &activity).await {
        activity = db
            .load_agent_workspace_member_activity(&daemon_id, workspace_id, member_id)
            .await?;
    }
    let details = format!("cancelled by {}", request.actor);
    let current = activity
        .signals
        .iter()
        .find(|record| record.signal.signal_id == signal_id);
    let acknowledged_at = match current.and_then(|record| record.acknowledgment.as_ref()) {
        None if current.is_some() => harness_workspace::workspace::utc_now(),
        Some(acknowledgment)
            if acknowledgment.result == AckResult::Rejected
                && acknowledgment.details.as_deref() == Some(details.as_str()) =>
        {
            acknowledgment.acknowledged_at.clone()
        }
        _ => {
            return db
                .acknowledge_agent_workspace_signal(
                    &daemon_id,
                    workspace_id,
                    member_id,
                    &AgentWorkspaceSignalAcknowledgment {
                        signal_id: signal_id.to_string(),
                        result: AckResult::Rejected,
                        details: Some(details),
                        acknowledged_at: None,
                    },
                )
                .await;
        }
    };
    let acknowledgment = AgentWorkspaceSignalAcknowledgment {
        signal_id: signal_id.to_string(),
        result: AckResult::Rejected,
        details: Some(details),
        acknowledged_at: Some(acknowledged_at.clone()),
    };
    let target = match db
        .load_agent_workspace_signal_cleanup_target(&daemon_id, workspace_id, member_id)
        .await
    {
        Ok(target) => target,
        Err(error) => {
            tracing::debug!(%error, member_id, signal_id, "runtime signal cancellation skipped");
            return db
                .acknowledge_agent_workspace_signal(
                    &daemon_id,
                    workspace_id,
                    member_id,
                    &acknowledgment,
                )
                .await;
        }
    };
    let runtime_acknowledgment = write_runtime_acknowledgment(
        &target,
        &SignalAck {
            signal_id: signal_id.to_string(),
            acknowledged_at,
            result: AckResult::Rejected,
            agent: member_id.to_string(),
            session_id: workspace_id.to_string(),
            details: acknowledgment.details.clone(),
        },
    )
    .await?;
    persist_runtime_acknowledgment(
        db,
        &daemon_id,
        workspace_id,
        member_id,
        &runtime_acknowledgment,
    )
    .await
}

async fn persist_runtime_acknowledgment(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    workspace_id: &str,
    member_id: &str,
    acknowledgment: &SignalAck,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    db.acknowledge_agent_workspace_signal(
        daemon_id,
        workspace_id,
        member_id,
        &AgentWorkspaceSignalAcknowledgment {
            signal_id: acknowledgment.signal_id.clone(),
            result: acknowledgment.result,
            details: acknowledgment.details.clone(),
            acknowledged_at: Some(acknowledgment.acknowledged_at.clone()),
        },
    )
    .await
}

async fn record_failed_signal_delivery(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    delivery_error: &CliError,
) -> Result<(), CliError> {
    db.acknowledge_agent_workspace_signal(
        daemon_id,
        workspace_id,
        member_id,
        &AgentWorkspaceSignalAcknowledgment {
            signal_id: signal_id.to_string(),
            result: AckResult::Deferred,
            details: Some(format!("runtime delivery failed: {delivery_error}")),
            acknowledged_at: None,
        },
    )
    .await
    .map(|_| ())
}

async fn reconcile_runtime_acknowledgments(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    response: &AgentWorkspaceMemberActivityResponse,
) -> bool {
    if response
        .signals
        .iter()
        .all(|signal| signal.acknowledgment.is_some())
    {
        return false;
    }
    let target = match db
        .load_agent_workspace_signal_target(daemon_id, &response.workspace_id, &response.member_id)
        .await
    {
        Ok(target) => target,
        Err(error) => {
            tracing::debug!(%error, member_id = response.member_id, "runtime acknowledgment scan skipped");
            return false;
        }
    };
    let Some(runtime) = runtime::runtime_for_name(&target.runtime) else {
        return false;
    };
    let signal_session_id = target
        .runtime_session_id
        .clone()
        .unwrap_or_else(|| target.workspace_id.clone());
    let mut acknowledgments = match read_runtime_acknowledgments_async(
        runtime,
        PathBuf::from(&target.project_dir),
        signal_session_id,
        "durable agent activity",
    )
    .await
    {
        Ok(acknowledgments) => acknowledgments,
        Err(error) => {
            tracing::warn!(%error, member_id = response.member_id, "runtime acknowledgment scan failed");
            return false;
        }
    };
    acknowledgments.sort_by(|left, right| {
        (&left.acknowledged_at, &left.signal_id).cmp(&(&right.acknowledged_at, &right.signal_id))
    });
    let mut changed = false;
    for acknowledgment in acknowledgments {
        let is_pending = response.signals.iter().any(|record| {
            record.signal.signal_id == acknowledgment.signal_id && record.acknowledgment.is_none()
        });
        if !is_pending {
            continue;
        }
        match db
            .acknowledge_agent_workspace_signal(
                daemon_id,
                &response.workspace_id,
                &response.member_id,
                &AgentWorkspaceSignalAcknowledgment {
                    signal_id: acknowledgment.signal_id.clone(),
                    result: acknowledgment.result,
                    details: acknowledgment.details.clone(),
                    acknowledged_at: Some(acknowledgment.acknowledged_at.clone()),
                },
            )
            .await
        {
            Ok(_) => changed = true,
            Err(error) => {
                tracing::warn!(%error, signal_id = acknowledgment.signal_id, "runtime acknowledgment import failed");
            }
        }
    }
    changed
}

async fn prepare_activity_scope(db: &AsyncDaemonDbHandle) -> Result<String, CliError> {
    let identity = tokio::task::spawn_blocking(state::ensure_daemon_identity)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join daemon identity read: {error}"))
        })??;
    db.reconcile_agent_workspaces(&identity.daemon_id).await?;
    Ok(identity.daemon_id)
}

async fn write_runtime_signal(
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
) -> Result<SignalFileState, CliError> {
    let runtime = runtime::runtime_for_name(&target.runtime).ok_or_else(|| {
        CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{}' for durable member '{}'",
            target.runtime, target.member_id
        ))
    })?;
    let project_dir = PathBuf::from(&target.project_dir);
    let signal_session_id = target
        .runtime_session_id
        .clone()
        .unwrap_or_else(|| target.workspace_id.clone());
    let signal = signal.clone();
    tokio::task::spawn_blocking(move || {
        runtime.ensure_signal(&project_dir, &signal_session_id, &signal)
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join durable signal write: {error}")))?
}

async fn write_runtime_acknowledgment(
    target: &AgentWorkspaceSignalTarget,
    acknowledgment: &SignalAck,
) -> Result<SignalAck, CliError> {
    let runtime = runtime::runtime_for_name(&target.runtime).ok_or_else(|| {
        CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{}' for durable member '{}'",
            target.runtime, target.member_id
        ))
    })?;
    let signal_session_id = target
        .runtime_session_id
        .clone()
        .unwrap_or_else(|| target.workspace_id.clone());
    let signal_dir = runtime.signal_dir(
        PathBuf::from(&target.project_dir).as_path(),
        &signal_session_id,
    );
    let acknowledgment = acknowledgment.clone();
    tokio::task::spawn_blocking(move || acknowledge_signal_once(&signal_dir, &acknowledgment))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join durable signal cancellation: {error}"))
        })?
}

fn scoped_signal_idempotency_key(
    workspace_id: &str,
    member_id: &str,
    actor: &str,
    idempotency_key: &str,
) -> String {
    let actor = actor.trim();
    format!(
        "{workspace_id}:{member_id}:{}:{actor}:{}",
        actor.len(),
        idempotency_key.trim()
    )
}

fn wake_managed_agent(
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
    dispatch: WakeDispatch<'_>,
) {
    let Some(runtime) = runtime::runtime_for_name(&target.runtime) else {
        return;
    };
    let prompt = build_active_signal_prompt(signal);
    match target.managed_agent_kind.as_str() {
        "tui" => {
            if let Some(manager) = dispatch.agent_tui
                && let Err(error) = manager.prompt_tui(&target.managed_agent_id, &prompt)
            {
                tracing::warn!(%error, member_id = target.member_id, "durable signal TUI wake failed");
            }
        }
        "acp" => {
            if let Some(manager) = dispatch.acp_agent {
                let signal_session_id = target
                    .runtime_session_id
                    .clone()
                    .unwrap_or_else(|| target.workspace_id.clone());
                manager.dispatch_wake_prompt(
                    runtime,
                    AcpWakePrompt {
                        acp_id: target.managed_agent_id.clone(),
                        orchestration_session_id: target.workspace_id.clone(),
                        signal_session_id: signal_session_id.clone(),
                        signal_dir: runtime.signal_dir(
                            PathBuf::from(&target.project_dir).as_path(),
                            &signal_session_id,
                        ),
                        project_dir: PathBuf::from(&target.project_dir),
                        prompt,
                        signal_id: signal.signal_id.clone(),
                        agent_id: target.member_id.clone(),
                    },
                );
            }
        }
        "codex" => {
            if let Some(controller) = dispatch.codex
                && let Err(error) =
                    controller.steer(&target.managed_agent_id, &CodexSteerRequest { prompt })
            {
                tracing::warn!(%error, member_id = target.member_id, "durable signal Codex wake failed");
            }
        }
        _ => {}
    }
}

fn validate_signal_request(request: &AgentWorkspaceSignalSendRequest) -> Result<(), CliError> {
    if request.idempotency_key.trim().is_empty() {
        return Err(CliErrorKind::workflow_io("signal idempotency key is empty").into());
    }
    if request.idempotency_key.trim().len() > 256 {
        return Err(CliErrorKind::workflow_io("signal idempotency key is too long").into());
    }
    if request.command.trim().is_empty() {
        return Err(CliErrorKind::workflow_io("signal command is empty").into());
    }
    if request.message.trim().is_empty() {
        return Err(CliErrorKind::workflow_io("signal message is empty").into());
    }
    Ok(())
}
