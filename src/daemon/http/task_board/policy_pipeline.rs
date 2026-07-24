use axum::Json;
use axum::Router;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};

use crate::daemon::protocol::{
    PolicyPipelineAuditRequest, PolicyPipelineGetRequest, PolicyPipelineGoLiveDiffRequest,
    PolicyPipelineMakeLiveRequest, PolicyPipelinePromoteRequest, PolicyPipelineReplayRequest,
    PolicyPipelineSaveDraftRequest, PolicyPipelineSimulateRequest, http_paths,
};

use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;

pub(super) fn merge_policy_pipeline_routes(
    router: Router<DaemonHttpState>,
) -> Router<DaemonHttpState> {
    router
        .route(
            http_paths::POLICY_PIPELINE,
            get(get_policy_pipeline).put(put_policy_pipeline_draft),
        )
        .route(http_paths::POLICY_SIMULATE, post(post_policy_simulate))
        .route(http_paths::POLICY_PROMOTE, post(post_policy_promote))
        .route(http_paths::POLICY_MAKE_LIVE, post(post_policy_make_live))
        .route(
            http_paths::POLICY_GO_LIVE_DIFF,
            post(post_policy_go_live_diff),
        )
        .route(http_paths::POLICY_REPLAY, post(post_policy_replay))
        .route(http_paths::POLICY_AUDIT, get(get_policy_audit))
}

pub(super) async fn get_policy_pipeline(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<PolicyPipelineGetRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let pipeline = match require_async_db(&state, "policy pipeline") {
        Ok(db) => task_board_route_executor::policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::POLICY_PIPELINE,
        &request_id,
        start,
        pipeline,
    )
}

pub(super) async fn put_policy_pipeline_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyPipelineSaveDraftRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let pipeline = match require_async_db(&state, "policy pipeline save draft") {
        Ok(db) => task_board_route_executor::save_policy_pipeline_draft(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "PUT",
        http_paths::POLICY_PIPELINE,
        &request_id,
        start,
        pipeline,
    )
}

pub(super) async fn post_policy_simulate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyPipelineSimulateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let pipeline = match require_async_db(&state, "policy pipeline simulate") {
        Ok(db) => task_board_route_executor::simulate_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_SIMULATE,
        &request_id,
        start,
        pipeline,
    )
}

pub(super) async fn post_policy_promote(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyPipelinePromoteRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let pipeline = match require_async_db(&state, "policy pipeline promote") {
        Ok(db) => task_board_route_executor::promote_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_PROMOTE,
        &request_id,
        start,
        pipeline,
    )
}

pub(super) async fn post_policy_make_live(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyPipelineMakeLiveRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let pipeline = match require_async_db(&state, "policy pipeline make live") {
        Ok(db) => task_board_route_executor::make_live_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_MAKE_LIVE,
        &request_id,
        start,
        pipeline,
    )
}

pub(super) async fn post_policy_go_live_diff(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyPipelineGoLiveDiffRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let diff = match require_async_db(&state, "policy pipeline go live diff") {
        Ok(db) => task_board_route_executor::go_live_diff_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_GO_LIVE_DIFF,
        &request_id,
        start,
        diff,
    )
}

pub(super) async fn post_policy_replay(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyPipelineReplayRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let replay = match require_async_db(&state, "policy pipeline replay") {
        Ok(db) => task_board_route_executor::replay_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_REPLAY,
        &request_id,
        start,
        replay,
    )
}

pub(super) async fn get_policy_audit(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<PolicyPipelineAuditRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let audit = match require_async_db(&state, "policy pipeline audit") {
        Ok(db) => task_board_route_executor::audit_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json("GET", http_paths::POLICY_AUDIT, &request_id, start, audit)
}
