//! HTTP handlers for the WP3 spawn-gate controls: the two persisted spawn
//! switches and the durable approval-grant list/resolve/revoke routes. Split out of
//! `policy.rs` to keep each file under the source-length cap.

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantRevokeRequest,
    PolicyCanvasSetSpawnKillSwitchRequest, PolicyCanvasSetSpawnRequiresLivePolicyRequest,
    http_paths,
};

use super::super::openapi::DaemonErrorBody;
use crate::daemon::protocol::{
    PolicyApprovalGrantResolveResponse, PolicyApprovalGrantRevokeResponse,
    PolicyApprovalGrantsListResponse, PolicyCanvasWorkspaceResponse,
};
use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;

pub(super) fn merge_policy_spawn_gate_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .routes(routes!(post_policy_canvas_set_spawn_requires_live_policy))
        .routes(routes!(post_policy_canvas_set_spawn_kill_switch))
        .routes(routes!(get_policy_approval_grants))
        .routes(routes!(post_policy_approval_grant_resolve))
        .routes(routes!(post_policy_approval_grant_revoke))
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/spawn-requires-live-policy",
    tag = "policy",
    description = "Toggle the fail-closed switch that requires a live enforced policy before an agent spawn is permitted, and return the updated workspace snapshot",
    request_body = PolicyCanvasSetSpawnRequiresLivePolicyRequest,
    responses(
        (status = 200, description = "Workspace after toggling the spawn-requires-live-policy switch", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_set_spawn_requires_live_policy(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasSetSpawnRequiresLivePolicyRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas spawn requires live policy") {
        Ok(db) => {
            task_board_route_executor::set_policy_canvas_spawn_requires_live_policy(db, &request)
                .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_SPAWN_REQUIRES_LIVE_POLICY,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/spawn-kill-switch",
    tag = "policy",
    description = "Toggle the emergency spawn kill switch that blocks all new agent spawns, and return the updated workspace snapshot",
    request_body = PolicyCanvasSetSpawnKillSwitchRequest,
    responses(
        (status = 200, description = "Workspace after toggling the spawn kill switch", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_set_spawn_kill_switch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasSetSpawnKillSwitchRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas spawn kill switch") {
        Ok(db) => {
            task_board_route_executor::set_policy_canvas_spawn_kill_switch(db, &request).await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_SPAWN_KILL_SWITCH,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    get,
    path = "/v1/policy-approval-grants",
    tag = "policy",
    description = "List the pending approval grants awaiting a human decision",
    responses(
        (status = 200, description = "All durable spawn-gate approval grants", body = PolicyApprovalGrantsListResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_policy_approval_grants(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let grants = match require_async_db(&state, "policy approval grants list") {
        Ok(db) => task_board_route_executor::list_policy_approval_grants(db).await,
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::POLICY_APPROVAL_GRANTS,
        &request_id,
        start,
        grants,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-approval-grants/resolve",
    tag = "policy",
    description = "Resolve a pending approval grant to approved or denied. Fails when the grant is missing or already resolved",
    request_body = PolicyApprovalGrantResolveRequest,
    responses(
        (status = 200, description = "The approval grant after approve or deny", body = PolicyApprovalGrantResolveResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_approval_grant_resolve(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyApprovalGrantResolveRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let resolved = match require_async_db(&state, "policy approval grant resolve") {
        Ok(db) => task_board_route_executor::resolve_policy_approval_grant(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_APPROVAL_GRANT_RESOLVE,
        &request_id,
        start,
        resolved,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-approval-grants/revoke",
    tag = "policy",
    description = "Revoke a live pending or approved approval grant. Fails when the grant is missing, terminal, consumed, or expired",
    request_body = PolicyApprovalGrantRevokeRequest,
    responses(
        (status = 200, description = "The approval grant after revocation", body = PolicyApprovalGrantRevokeResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_approval_grant_revoke(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyApprovalGrantRevokeRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let revoked = match require_async_db(&state, "policy approval grant revoke") {
        Ok(db) => task_board_route_executor::revoke_policy_approval_grant(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_APPROVAL_GRANT_REVOKE,
        &request_id,
        start,
        revoked,
    )
}
