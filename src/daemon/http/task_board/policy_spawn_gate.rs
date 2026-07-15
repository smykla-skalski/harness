//! HTTP handlers for the WP3 spawn-gate controls: the two persisted spawn
//! switches and the durable approval-grant list/resolve/revoke routes. Split out of
//! `policy.rs` to keep each file under the source-length cap.

use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};

use crate::daemon::protocol::{
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantRevokeRequest,
    PolicyCanvasSetSpawnKillSwitchRequest, PolicyCanvasSetSpawnRequiresLivePolicyRequest,
    http_paths,
};

use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;

pub(super) fn merge_policy_spawn_gate_routes(
    router: Router<DaemonHttpState>,
) -> Router<DaemonHttpState> {
    router
        .route(
            http_paths::POLICY_CANVASES_SPAWN_REQUIRES_LIVE_POLICY,
            post(post_policy_canvas_set_spawn_requires_live_policy),
        )
        .route(
            http_paths::POLICY_CANVASES_SPAWN_KILL_SWITCH,
            post(post_policy_canvas_set_spawn_kill_switch),
        )
        .route(
            http_paths::POLICY_APPROVAL_GRANTS,
            get(get_policy_approval_grants),
        )
        .route(
            http_paths::POLICY_APPROVAL_GRANT_RESOLVE,
            post(post_policy_approval_grant_resolve),
        )
        .route(
            http_paths::POLICY_APPROVAL_GRANT_REVOKE,
            post(post_policy_approval_grant_revoke),
        )
}

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
