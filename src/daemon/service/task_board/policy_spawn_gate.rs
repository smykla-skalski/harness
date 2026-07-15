//! Service handlers for the WP3 spawn-gate controls: the two persisted spawn
//! switches and the durable approval-grant list/resolve/revoke routes. Split out of
//! `policy_canvas.rs` to keep each file under the source-length cap.

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    PolicyApprovalGrantRevokeRequest, PolicyApprovalGrantRevokeResponse,
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantResolveResponse,
    PolicyApprovalGrantsListResponse, PolicyCanvasSetSpawnKillSwitchRequest,
    PolicyCanvasSetSpawnRequiresLivePolicyRequest, PolicyCanvasWorkspaceResponse,
};
use crate::errors::CliError;
use crate::task_board::policy_graph;

use super::policy_canvas::{bump_change_policy, feed_gate_cache};
use super::policy_canvas_response::policy_canvas_workspace_response;

/// Default actor recorded on a grant resolution when the caller omits one.
const DEFAULT_APPROVAL_ACTOR: &str = "operator";

/// Toggle the fail-closed "spawn requires a live enforced policy" switch.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn set_policy_canvas_spawn_requires_live_policy(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasSetSpawnRequiresLivePolicyRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    let enabled = request.enabled;
    let (workspace, _enabled) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            Ok(policy_graph::apply_set_spawn_requires_live_policy(
                workspace, enabled,
            ))
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Toggle the emergency spawn kill switch.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn set_policy_canvas_spawn_kill_switch(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasSetSpawnKillSwitchRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    let enabled = request.enabled;
    let (workspace, _enabled) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            Ok(policy_graph::apply_set_spawn_kill_switch(
                workspace, enabled,
            ))
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// List the pending approval grants awaiting a human decision.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be read.
pub(crate) async fn list_policy_approval_grants(
    db: &AsyncDaemonDb,
) -> Result<PolicyApprovalGrantsListResponse, CliError> {
    let grants = db.list_pending_approval_grants().await?;
    Ok(PolicyApprovalGrantsListResponse { grants })
}

/// Resolve a pending approval grant to approved or denied.
///
/// # Errors
/// Returns `CliError` when the grant is missing, already resolved, or the write
/// fails.
pub(crate) async fn resolve_policy_approval_grant(
    db: &AsyncDaemonDb,
    request: &PolicyApprovalGrantResolveRequest,
) -> Result<PolicyApprovalGrantResolveResponse, CliError> {
    let actor = request.actor.as_deref().unwrap_or(DEFAULT_APPROVAL_ACTOR);
    let grant = db
        .resolve_approval_grant(&request.grant_id, request.approve, actor)
        .await?;
    bump_change_policy(db).await;
    Ok(PolicyApprovalGrantResolveResponse { grant })
}

/// Revoke a live pending or approved grant.
///
/// # Errors
/// Returns `CliError` when the grant is missing, terminal, consumed, expired,
/// or the write fails.
pub(crate) async fn revoke_policy_approval_grant(
    db: &AsyncDaemonDb,
    request: &PolicyApprovalGrantRevokeRequest,
) -> Result<PolicyApprovalGrantRevokeResponse, CliError> {
    let actor = request.actor.as_deref().unwrap_or(DEFAULT_APPROVAL_ACTOR);
    let grant = db
        .revoke_approval_grant(&request.grant_id, actor)
        .await?;
    bump_change_policy(db).await;
    Ok(PolicyApprovalGrantRevokeResponse { grant })
}
