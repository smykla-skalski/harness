use harness_agents::runtime::signal::{AckResult, SignalFileState};
use harness_daemon_db_queries::AgentWorkspaceSignalAcknowledgment;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::{
    AgentWorkspaceActivityWindowResponse, AgentWorkspaceMemberActivityResponse,
    AgentWorkspaceSignalAckRequest, AgentWorkspaceSignalCancelRequest, AgentWorkspaceSignalRecord,
    AgentWorkspaceSignalSendRequest,
};
use harness_protocol::session::SessionSignalStatus;
use harness_protocol::timeline::TimelineWindowRequest;

use super::wake_route::WakeDispatch;
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::state;

mod runtime_ack_import;
mod runtime_delivery;
mod wake_delivery;

use runtime_delivery::{
    persist_durable_acknowledgment, persist_runtime_acknowledgment, record_failed_signal_delivery,
    runtime_acknowledgment, runtime_signal_session_id, scoped_signal_idempotency_key,
    settle_expired_runtime_signal, settle_runtime_acknowledgment, write_runtime_signal,
};
use wake_delivery::wake_managed_agent;

pub(super) async fn record_native_runtime_acknowledgment_from_session_route(
    db: &AsyncDaemonDbHandle,
    source_session_id: &str,
    source_agent_id: &str,
    signal_id: &str,
) -> Result<bool, CliError> {
    runtime_ack_import::record_native_runtime_acknowledgment_from_session_route(
        db,
        source_session_id,
        source_agent_id,
        signal_id,
    )
    .await
}

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
    if runtime_ack_import::reconcile_runtime_acknowledgments_for_read(db, &daemon_id, &response)
        .await
    {
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
    if !insertion.inserted {
        if insertion.record.acknowledgment.is_some() {
            return Ok(insertion.record);
        }
        if insertion.record.status == SessionSignalStatus::Expired {
            let acknowledgment =
                settle_expired_runtime_signal(&target, &insertion.record.signal).await?;
            return persist_runtime_acknowledgment(
                db,
                &daemon_id,
                workspace_id,
                member_id,
                &acknowledgment,
            )
            .await;
        }
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
        SignalFileState::Created | SignalFileState::Pending => {
            wake_managed_agent(db, &daemon_id, &target, &record.signal, dispatch).await?;
            Ok(record)
        }
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
    let activity = db
        .load_agent_workspace_member_activity(&daemon_id, workspace_id, member_id)
        .await?;
    let durable_request = AgentWorkspaceSignalAcknowledgment {
        signal_id: signal_id.to_string(),
        result: request.result,
        details: request.details.clone(),
        acknowledged_at: None,
    };
    let Some(current) = activity
        .signals
        .into_iter()
        .find(|record| record.signal.signal_id == signal_id)
    else {
        return persist_durable_acknowledgment(
            db,
            &daemon_id,
            workspace_id,
            member_id,
            &durable_request,
        )
        .await;
    };
    let acknowledged_at = match current.acknowledgment.as_ref() {
        None => harness_workspace::workspace::utc_now(),
        Some(acknowledgment)
            if acknowledgment.result == request.result
                && acknowledgment.details == request.details =>
        {
            acknowledgment.acknowledged_at.clone()
        }
        Some(_) => {
            return persist_durable_acknowledgment(
                db,
                &daemon_id,
                workspace_id,
                member_id,
                &durable_request,
            )
            .await;
        }
    };
    let target = match db
        .load_agent_workspace_signal_cleanup_target(&daemon_id, workspace_id, member_id)
        .await
    {
        Ok(target) => target,
        Err(error) => {
            tracing::debug!(%error, member_id, signal_id, "runtime signal acknowledgment skipped");
            return persist_durable_acknowledgment(
                db,
                &daemon_id,
                workspace_id,
                member_id,
                &durable_request,
            )
            .await;
        }
    };
    let runtime_acknowledgment = settle_runtime_acknowledgment(
        &target,
        &current.signal,
        &runtime_acknowledgment(
            &target,
            signal_id,
            acknowledged_at,
            request.result,
            request.details.clone(),
        ),
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
    if runtime_ack_import::reconcile_runtime_acknowledgments_for_read(db, &daemon_id, &activity)
        .await
    {
        activity = db
            .load_agent_workspace_member_activity(&daemon_id, workspace_id, member_id)
            .await?;
    }
    let details = format!("cancelled by {}", request.actor);
    let Some(current) = activity
        .signals
        .into_iter()
        .find(|record| record.signal.signal_id == signal_id)
    else {
        return persist_durable_acknowledgment(
            db,
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
    };
    let acknowledged_at = match current.acknowledgment.as_ref() {
        None => harness_workspace::workspace::utc_now(),
        Some(acknowledgment)
            if acknowledgment.result == AckResult::Rejected
                && acknowledgment.details.as_deref() == Some(details.as_str()) =>
        {
            acknowledgment.acknowledged_at.clone()
        }
        _ => {
            return persist_durable_acknowledgment(
                db,
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
            return persist_durable_acknowledgment(
                db,
                &daemon_id,
                workspace_id,
                member_id,
                &acknowledgment,
            )
            .await;
        }
    };
    let runtime_acknowledgment = settle_runtime_acknowledgment(
        &target,
        &current.signal,
        &runtime_acknowledgment(
            &target,
            signal_id,
            acknowledged_at,
            AckResult::Rejected,
            acknowledgment.details.clone(),
        ),
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

async fn prepare_activity_scope(db: &AsyncDaemonDbHandle) -> Result<String, CliError> {
    let identity = tokio::task::spawn_blocking(state::ensure_daemon_identity)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join daemon identity read: {error}"))
        })??;
    db.reconcile_agent_workspaces(&identity.daemon_id).await?;
    Ok(identity.daemon_id)
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
