use std::path::PathBuf;

use harness_agents::runtime;
use harness_agents::runtime::signal::{
    AckResult, Signal, SignalAck, SignalFileState, SignalSettlement, acknowledge_signal_once,
    acknowledgments_match, settle_signal_if_present,
};
use harness_daemon_db_queries::{AgentWorkspaceSignalAcknowledgment, AgentWorkspaceSignalTarget};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::AgentWorkspaceSignalRecord;

use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

pub(super) async fn persist_runtime_acknowledgment(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    workspace_id: &str,
    member_id: &str,
    acknowledgment: &SignalAck,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    persist_durable_acknowledgment(
        db,
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

pub(super) async fn record_failed_signal_delivery(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    delivery_error: &CliError,
) -> Result<(), CliError> {
    persist_durable_acknowledgment(
        db,
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

pub(super) async fn persist_durable_acknowledgment(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    workspace_id: &str,
    member_id: &str,
    acknowledgment: &AgentWorkspaceSignalAcknowledgment,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    db.acknowledge_agent_workspace_signal(daemon_id, workspace_id, member_id, acknowledgment)
        .await
}

pub(super) async fn settle_runtime_acknowledgment(
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
    requested: &SignalAck,
) -> Result<SignalAck, CliError> {
    match write_runtime_signal(target, signal).await? {
        SignalFileState::Created | SignalFileState::Pending => {
            write_runtime_acknowledgment(target, requested).await
        }
        SignalFileState::Acknowledged(existing) if acknowledgments_match(&existing, requested) => {
            Ok(existing)
        }
        SignalFileState::Acknowledged(_) => Err(CliErrorKind::session_agent_conflict(format!(
            "signal '{}' already has a different runtime acknowledgment",
            requested.signal_id
        ))
        .into()),
    }
}

pub(super) async fn settle_expired_runtime_signal(
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
) -> Result<SignalAck, CliError> {
    let requested = runtime_acknowledgment(
        target,
        &signal.signal_id,
        harness_workspace::workspace::utc_now(),
        AckResult::Expired,
        Some("expired before agent acknowledged delivery".to_string()),
    );
    let runtime = runtime::runtime_for_name(&target.runtime).ok_or_else(|| {
        CliErrorKind::session_agent_conflict(format!(
            "unknown runtime '{}' for durable member '{}'",
            target.runtime, target.member_id
        ))
    })?;
    let signal_dir = runtime.signal_dir(
        PathBuf::from(&target.project_dir).as_path(),
        &runtime_signal_session_id(target),
    );
    let runtime_request = requested.clone();
    let settlement = tokio::task::spawn_blocking(move || {
        settle_signal_if_present(&signal_dir, &runtime_request)
    })
    .await
    .map_err(|error| {
        CliErrorKind::workflow_io(format!("join expired signal settlement: {error}"))
    })??;
    Ok(match settlement {
        SignalSettlement::Missing => requested,
        SignalSettlement::Acknowledged(existing) => existing,
    })
}

pub(super) async fn write_runtime_signal(
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
    let signal_session_id = runtime_signal_session_id(target);
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
    let signal_session_id = runtime_signal_session_id(target);
    let signal_dir = runtime.signal_dir(
        PathBuf::from(&target.project_dir).as_path(),
        &signal_session_id,
    );
    let acknowledgment = acknowledgment.clone();
    tokio::task::spawn_blocking(move || acknowledge_signal_once(&signal_dir, &acknowledgment))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join durable signal acknowledgment: {error}"))
        })?
}

pub(super) fn runtime_acknowledgment(
    target: &AgentWorkspaceSignalTarget,
    signal_id: &str,
    acknowledged_at: String,
    result: AckResult,
    details: Option<String>,
) -> SignalAck {
    SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at,
        result,
        agent: runtime_signal_session_id(target),
        session_id: runtime_orchestration_session_id(target),
        details,
    }
}

pub(super) fn runtime_signal_session_id(target: &AgentWorkspaceSignalTarget) -> String {
    target
        .runtime_session_id
        .clone()
        .unwrap_or_else(|| target.workspace_id.clone())
}

pub(super) fn runtime_orchestration_session_id(target: &AgentWorkspaceSignalTarget) -> String {
    target
        .source_session_id
        .clone()
        .unwrap_or_else(|| target.workspace_id.clone())
}

pub(super) fn scoped_signal_idempotency_key(
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
