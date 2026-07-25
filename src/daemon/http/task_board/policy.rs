use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    PolicyCanvasCreateRequest, PolicyCanvasDeleteRequest, PolicyCanvasDuplicateRequest,
    PolicyCanvasRenameRequest, PolicyCanvasSetActiveRequest,
    PolicyCanvasSetGlobalEnforcementRequest, PolicyScenarioCreateRequest,
    PolicyScenarioDeleteRequest, PolicyScenarioUpdateRequest, http_paths,
};

use super::super::openapi::DaemonErrorBody;
use crate::daemon::protocol::PolicyCanvasWorkspaceResponse;
use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;

pub(super) fn merge_policy_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .routes(routes!(get_policy_canvas_workspace))
        .routes(routes!(post_policy_canvas_create))
        .routes(routes!(post_policy_canvas_duplicate))
        .routes(routes!(post_policy_canvas_rename))
        .routes(routes!(post_policy_canvas_set_active))
        .routes(routes!(post_policy_canvas_delete))
        .routes(routes!(post_policy_canvas_set_global_enforcement))
        .routes(routes!(post_policy_scenario_create))
        .routes(routes!(post_policy_scenario_update))
        .routes(routes!(post_policy_scenario_delete))
        .routes(routes!(post_policy_scenario_reset))
}

#[utoipa::path(
    get,
    path = "/v1/policy-canvases",
    tag = "policy",
    description = "Return the full policy-canvas workspace snapshot, seeding a default workspace with built-in automation canvases and scenarios on first use",
    responses(
        (status = 200, description = "The full policy-canvas workspace", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_policy_canvas_workspace(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas workspace") {
        Ok(db) => task_board_route_executor::policy_canvas_workspace(db).await,
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::POLICY_CANVASES,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/create",
    tag = "policy",
    description = "Create a new policy canvas and return the updated workspace snapshot",
    request_body = PolicyCanvasCreateRequest,
    responses(
        (status = 200, description = "Workspace after creating the canvas", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_create(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasCreateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas create") {
        Ok(db) => task_board_route_executor::create_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_CREATE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/duplicate",
    tag = "policy",
    description = "Duplicate an existing policy canvas under a new title and return the updated workspace snapshot",
    request_body = PolicyCanvasDuplicateRequest,
    responses(
        (status = 200, description = "Workspace after duplicating the canvas", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_duplicate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasDuplicateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas duplicate") {
        Ok(db) => task_board_route_executor::duplicate_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_DUPLICATE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/rename",
    tag = "policy",
    description = "Rename an existing policy canvas and return the updated workspace snapshot",
    request_body = PolicyCanvasRenameRequest,
    responses(
        (status = 200, description = "Workspace after renaming the canvas", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_rename(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasRenameRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas rename") {
        Ok(db) => task_board_route_executor::rename_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_RENAME,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/active",
    tag = "policy",
    description = "Switch the authoritative active policy canvas and return the updated workspace snapshot",
    request_body = PolicyCanvasSetActiveRequest,
    responses(
        (status = 200, description = "Workspace after selecting the active canvas", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_set_active(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasSetActiveRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas set active") {
        Ok(db) => task_board_route_executor::set_active_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_ACTIVE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/delete",
    tag = "policy",
    description = "Delete an existing policy canvas and return the updated workspace snapshot",
    request_body = PolicyCanvasDeleteRequest,
    responses(
        (status = 200, description = "Workspace after deleting the canvas", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasDeleteRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas delete") {
        Ok(db) => task_board_route_executor::delete_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_DELETE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-canvases/global-enforcement",
    tag = "policy",
    description = "Toggle the global policy enforcement gate without mutating any policy canvas, and return the updated workspace snapshot",
    request_body = PolicyCanvasSetGlobalEnforcementRequest,
    responses(
        (status = 200, description = "Workspace after toggling global enforcement", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_canvas_set_global_enforcement(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasSetGlobalEnforcementRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy canvas global enforcement") {
        Ok(db) => {
            task_board_route_executor::set_policy_canvas_global_enforcement(db, &request).await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVASES_GLOBAL_ENFORCEMENT,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-scenarios/create",
    tag = "policy",
    description = "Create a new editable policy scenario used for confidence simulation and return the updated workspace snapshot. Scenarios feed only the simulation and never affect the live enforcement gate",
    request_body = PolicyScenarioCreateRequest,
    responses(
        (status = 200, description = "Workspace after creating the scenario", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_scenario_create(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyScenarioCreateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy scenario create") {
        Ok(db) => task_board_route_executor::create_policy_scenario(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_SCENARIOS_CREATE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-scenarios/update",
    tag = "policy",
    description = "Update an existing policy scenario's name and input, and return the updated workspace snapshot",
    request_body = PolicyScenarioUpdateRequest,
    responses(
        (status = 200, description = "Workspace after updating the scenario", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_scenario_update(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyScenarioUpdateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy scenario update") {
        Ok(db) => task_board_route_executor::update_policy_scenario(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_SCENARIOS_UPDATE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-scenarios/delete",
    tag = "policy",
    description = "Delete a policy scenario and return the updated workspace snapshot",
    request_body = PolicyScenarioDeleteRequest,
    responses(
        (status = 200, description = "Workspace after deleting the scenario", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_scenario_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyScenarioDeleteRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy scenario delete") {
        Ok(db) => task_board_route_executor::delete_policy_scenario(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_SCENARIOS_DELETE,
        &request_id,
        start,
        workspace,
    )
}

#[utoipa::path(
    post,
    path = "/v1/policy-scenarios/reset",
    tag = "policy",
    description = "Restore the built-in seeded scenario set, discarding any custom scenarios, and return the updated workspace snapshot",
    responses(
        (status = 200, description = "Workspace after resetting scenarios to the built-in set", body = PolicyCanvasWorkspaceResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_policy_scenario_reset(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let workspace = match require_async_db(&state, "policy scenario reset") {
        Ok(db) => task_board_route_executor::reset_policy_scenarios(db).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_SCENARIOS_RESET,
        &request_id,
        start,
        workspace,
    )
}
