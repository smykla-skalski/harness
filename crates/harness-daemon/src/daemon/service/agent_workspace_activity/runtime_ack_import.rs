use std::path::PathBuf;

use harness_agents::runtime;
use harness_daemon_db_queries::AgentWorkspaceSignalAcknowledgment;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::AgentWorkspaceMemberActivityResponse;

use super::super::sync_support::read_runtime_acknowledgments_async;
use super::{
    AsyncDaemonDbHandle, persist_durable_acknowledgment, prepare_activity_scope,
    runtime_signal_session_id,
};
use crate::daemon::db::prelude::*;

pub(super) async fn reconcile_runtime_acknowledgments_for_read(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    response: &AgentWorkspaceMemberActivityResponse,
) -> bool {
    match reconcile_runtime_acknowledgments(db, daemon_id, response, None).await {
        Ok(changed) => changed,
        Err(error) => {
            tracing::warn!(
                %error,
                member_id = response.member_id,
                "runtime acknowledgment scan failed"
            );
            false
        }
    }
}

pub(super) async fn record_native_runtime_acknowledgment_from_session_route(
    db: &AsyncDaemonDbHandle,
    source_session_id: &str,
    source_agent_id: &str,
    signal_id: &str,
) -> Result<bool, CliError> {
    let daemon_id = prepare_activity_scope(db).await?;
    let Some(route) = db
        .load_agent_workspace_signal_route(
            &daemon_id,
            source_session_id,
            source_agent_id,
            signal_id,
        )
        .await?
    else {
        return Ok(false);
    };
    let activity = db
        .load_agent_workspace_member_activity(&daemon_id, &route.workspace_id, &route.member_id)
        .await?;
    let signal = activity
        .signals
        .iter()
        .find(|record| record.signal.signal_id == signal_id)
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "native signal '{signal_id}' disappeared from its compatibility route"
            ))
        })?;
    if signal.acknowledgment.is_some() {
        return Ok(true);
    }
    if !reconcile_runtime_acknowledgments(db, &daemon_id, &activity, Some(signal_id)).await? {
        return Err(CliErrorKind::workflow_io(format!(
            "native signal '{signal_id}' has no runtime acknowledgment to import"
        ))
        .into());
    }
    Ok(true)
}

async fn reconcile_runtime_acknowledgments(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    response: &AgentWorkspaceMemberActivityResponse,
    signal_filter: Option<&str>,
) -> Result<bool, CliError> {
    if !response.signals.iter().any(|signal| {
        signal.acknowledgment.is_none()
            && signal_filter.is_none_or(|filter| signal.signal.signal_id == filter)
    }) {
        return Ok(false);
    }
    let target = db
        .load_agent_workspace_signal_cleanup_target(
            daemon_id,
            &response.workspace_id,
            &response.member_id,
        )
        .await?;
    let runtime = runtime::runtime_for_name(&target.runtime).ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "runtime '{}' cannot import durable acknowledgments",
            target.runtime
        ))
    })?;
    let signal_session_id = runtime_signal_session_id(&target);
    let mut acknowledgments = read_runtime_acknowledgments_async(
        runtime,
        PathBuf::from(&target.project_dir),
        signal_session_id,
        "durable agent activity",
    )
    .await?;
    acknowledgments.sort_by(|left, right| {
        (&left.acknowledged_at, &left.signal_id).cmp(&(&right.acknowledged_at, &right.signal_id))
    });
    let mut changed = false;
    for acknowledgment in acknowledgments {
        let is_pending = response.signals.iter().any(|record| {
            record.signal.signal_id == acknowledgment.signal_id
                && record.acknowledgment.is_none()
                && signal_filter.is_none_or(|filter| acknowledgment.signal_id == filter)
        });
        if !is_pending {
            continue;
        }
        persist_durable_acknowledgment(
            db,
            daemon_id,
            &response.workspace_id,
            &response.member_id,
            &AgentWorkspaceSignalAcknowledgment {
                signal_id: acknowledgment.signal_id,
                result: acknowledgment.result,
                details: acknowledgment.details,
                acknowledged_at: Some(acknowledgment.acknowledged_at),
            },
        )
        .await?;
        changed = true;
    }
    Ok(changed)
}
