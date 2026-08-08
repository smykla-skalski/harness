use std::collections::BTreeMap;
use std::path::PathBuf;

use harness_agents::runtime;
use harness_daemon_db_queries::{AgentWorkspaceSignalAcknowledgment, AgentWorkspaceSignalRoute};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::AgentWorkspaceMemberActivityResponse;

use super::super::sync_support::read_runtime_acknowledgments_async;
use super::{AsyncDaemonDbHandle, persist_durable_acknowledgment, prepare_activity_scope};
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
    import_native_runtime_acknowledgment(db, &daemon_id, &route).await?;
    Ok(true)
}

async fn import_native_runtime_acknowledgment(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    route: &AgentWorkspaceSignalRoute,
) -> Result<(), CliError> {
    let activity = db
        .load_agent_workspace_member_activity(daemon_id, &route.workspace_id, &route.member_id)
        .await?;
    let signal = activity
        .signals
        .iter()
        .find(|record| record.signal.signal_id == route.signal_id)
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "native signal '{}' disappeared from its durable route",
                route.signal_id
            ))
        })?;
    if signal.acknowledgment.is_some() {
        return Ok(());
    }
    let Some(acknowledgment) = read_route_acknowledgment(route).await? else {
        return Err(CliErrorKind::workflow_io(format!(
            "native signal '{}' has no runtime acknowledgment to import",
            route.signal_id
        ))
        .into());
    };
    persist_acknowledgment(db, daemon_id, route, acknowledgment).await?;
    Ok(())
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
    let routes = db
        .load_pending_agent_workspace_signal_routes(
            daemon_id,
            &response.workspace_id,
            &response.member_id,
        )
        .await?;
    let mut routes_by_runtime = BTreeMap::new();
    for route in routes {
        if signal_filter.is_some_and(|filter| route.signal_id != filter) {
            continue;
        }
        routes_by_runtime
            .entry((
                route.runtime.clone(),
                route.runtime_session_id.clone(),
                route.project_dir.clone(),
            ))
            .or_insert_with(BTreeMap::new)
            .insert(route.signal_id.clone(), route);
    }
    let mut changed = false;
    for routes in routes_by_runtime.into_values() {
        let Some(sample_route) = routes.values().next() else {
            continue;
        };
        for acknowledgment in read_route_acknowledgments(sample_route).await? {
            let Some(route) = routes.get(&acknowledgment.signal_id) else {
                continue;
            };
            persist_acknowledgment(db, daemon_id, route, acknowledgment).await?;
            changed = true;
        }
    }
    Ok(changed)
}

async fn read_route_acknowledgment(
    route: &AgentWorkspaceSignalRoute,
) -> Result<Option<harness_protocol::agent::SignalAck>, CliError> {
    Ok(read_route_acknowledgments(route)
        .await?
        .into_iter()
        .find(|acknowledgment| acknowledgment.signal_id == route.signal_id))
}

async fn read_route_acknowledgments(
    route: &AgentWorkspaceSignalRoute,
) -> Result<Vec<harness_protocol::agent::SignalAck>, CliError> {
    let runtime = runtime::runtime_for_name(&route.runtime).ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "runtime '{}' cannot import durable acknowledgments",
            route.runtime
        ))
    })?;
    read_runtime_acknowledgments_async(
        runtime,
        PathBuf::from(&route.project_dir),
        route.runtime_session_id.clone(),
        "durable agent activity",
    )
    .await
}

async fn persist_acknowledgment(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    route: &AgentWorkspaceSignalRoute,
    acknowledgment: harness_protocol::agent::SignalAck,
) -> Result<(), CliError> {
    persist_durable_acknowledgment(
        db,
        daemon_id,
        &route.workspace_id,
        &route.member_id,
        &AgentWorkspaceSignalAcknowledgment {
            signal_id: acknowledgment.signal_id,
            result: acknowledgment.result,
            details: acknowledgment.details,
            acknowledged_at: Some(acknowledgment.acknowledged_at),
        },
    )
    .await
    .map(|_| ())
}
