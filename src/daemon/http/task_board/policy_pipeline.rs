use axum::Json;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    PolicyPipelineAuditRequest, PolicyPipelineGetRequest, PolicyPipelineGoLiveDiffRequest,
    PolicyPipelineMakeLiveRequest, PolicyPipelinePromoteRequest, PolicyPipelineReplayRequest,
    PolicyPipelineSaveDraftRequest, PolicyPipelineSimulateRequest, http_paths,
};

use super::super::openapi::DaemonErrorBody;
use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;
use crate::daemon::protocol::{
    PolicyPipelineAuditResponse, PolicyPipelineGoLiveDiffResponse, PolicyPipelineMakeLiveResponse,
    PolicyPipelinePromoteResponse, PolicyPipelineReplayResponse, PolicyPipelineResponse,
    PolicyPipelineSaveDraftResponse, PolicyPipelineSimulationResponse,
};

pub(super) fn merge_policy_pipeline_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .merge(policy_pipeline_draft_routes())
        .merge(policy_pipeline_promotion_routes())
}

fn policy_pipeline_draft_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_policy_pipeline, put_policy_pipeline_draft))
        .routes(routes!(post_policy_simulate))
}

fn policy_pipeline_promotion_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_policy_promote))
        .routes(routes!(post_policy_make_live))
        .routes(routes!(post_policy_go_live_diff))
        .routes(routes!(post_policy_replay))
        .routes(routes!(get_policy_audit))
}

#[utoipa::path(
    get,
    path = "/v1/policy-pipeline",
    tag = "policy",
    description = "Load the V2 policy pipeline draft document for the active canvas, or for a specific canvas when `canvas_id` is provided",
    params(PolicyPipelineGetRequest),
    responses(
        (status = 200, description = "The draft policy graph for the selected canvas", body = PolicyPipelineResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/policy-pipeline",
    tag = "policy",
    description = "Validate and persist a policy pipeline draft for a canvas, returning the validation outcome and, when valid, the persisted draft. The request requires `canvas_id`; omitting it fails with an invalid-transition error",
    request_body = PolicyPipelineSaveDraftRequest,
    responses(
        (status = 200, description = "Validation outcome and, when valid, the persisted draft", body = PolicyPipelineSaveDraftResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/policy-pipeline/simulate",
    tag = "policy",
    description = "Simulate a policy pipeline draft against the confidence scenario set and return per-scenario decisions without promoting the draft to live",
    request_body = PolicyPipelineSimulateRequest,
    responses(
        (status = 200, description = "Non-persisting simulation of the draft against the scenario set", body = PolicyPipelineSimulationResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/policy-pipeline/promote",
    tag = "policy",
    description = "Promote a policy pipeline draft to the canvas's enforced live document and return the resulting document and trace ID. Internally this runs the same live-promotion path as `make-live`, including enabling global enforcement, but the response omits the enforcement flag and refreshed workspace",
    request_body = PolicyPipelinePromoteRequest,
    responses(
        (status = 200, description = "The promoted draft revision", body = PolicyPipelinePromoteResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/policy-pipeline/make-live",
    tag = "policy",
    description = "Make a policy pipeline draft the canvas's live enforced document: refresh its simulation, promote it to enforced mode, and enable global policy enforcement in one transaction",
    request_body = PolicyPipelineMakeLiveRequest,
    responses(
        (status = 200, description = "The now-live document and refreshed workspace", body = PolicyPipelineMakeLiveResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/policy-pipeline/go-live-diff",
    tag = "policy",
    description = "Diff a candidate draft against the currently live enforced policy across every scenario without mutating any durable state",
    request_body = PolicyPipelineGoLiveDiffRequest,
    responses(
        (status = 200, description = "Per-scenario decision diff between the live policy and the draft", body = PolicyPipelineGoLiveDiffResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/policy-pipeline/replay",
    tag = "policy",
    description = "Replay the active draft against a window of recently recorded real policy decisions for the canvas, without mutating any durable state",
    request_body = PolicyPipelineReplayRequest,
    responses(
        (status = 200, description = "The draft replayed against a window of recorded decisions", body = PolicyPipelineReplayResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/policy-pipeline/audit",
    tag = "policy",
    description = "Summarize the active-revision status, latest simulation, and pending approval grant count for the V2 policy pipeline",
    params(PolicyPipelineAuditRequest),
    responses(
        (status = 200, description = "Active-revision and latest-simulation audit summary", body = PolicyPipelineAuditResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
