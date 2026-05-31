use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post, put};
use axum::{Json, Router};

use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineGetRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest, http_paths,
};

use super::DaemonHttpState;
use super::require_async_db;
use super::response::timed_json;
use super::task_board_orchestrator_handlers::merge_orchestrator_routes;
use super::task_board_route_executor;

mod items;

pub(super) use self::items::{authenticated_request, authorized_control_request_parts};

use self::items::{
    delete_task_board_item, get_task_board_audit, get_task_board_host_list,
    get_task_board_host_local, get_task_board_item, get_task_board_items, get_task_board_machines,
    get_task_board_projects, post_task_board_dispatch, post_task_board_evaluate,
    post_task_board_item, post_task_board_plan_approve, post_task_board_plan_begin,
    post_task_board_plan_revoke, post_task_board_plan_submit, post_task_board_sync,
    put_task_board_host_set_project_types, put_task_board_item,
};

fn task_board_host_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::TASK_BOARD_HOST_LOCAL,
            get(get_task_board_host_local),
        )
        .route(
            http_paths::TASK_BOARD_HOST_LIST,
            get(get_task_board_host_list),
        )
        .route(
            http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
            put(put_task_board_host_set_project_types),
        )
}

pub(super) fn task_board_routes() -> Router<DaemonHttpState> {
    let router = Router::new()
        .route(
            http_paths::TASK_BOARD_ITEMS,
            post(post_task_board_item).get(get_task_board_items),
        )
        .route(
            http_paths::TASK_BOARD_ITEM,
            get(get_task_board_item)
                .put(put_task_board_item)
                .delete(delete_task_board_item),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_BEGIN,
            post(post_task_board_plan_begin),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_SUBMIT,
            post(post_task_board_plan_submit),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_APPROVE,
            post(post_task_board_plan_approve),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_REVOKE,
            post(post_task_board_plan_revoke),
        )
        .route(http_paths::TASK_BOARD_SYNC, post(post_task_board_sync))
        .route(
            http_paths::TASK_BOARD_DISPATCH,
            post(post_task_board_dispatch),
        )
        .route(
            http_paths::TASK_BOARD_EVALUATE,
            post(post_task_board_evaluate),
        )
        .route(http_paths::TASK_BOARD_AUDIT, get(get_task_board_audit))
        .route(
            http_paths::TASK_BOARD_PROJECTS,
            get(get_task_board_projects),
        )
        .route(
            http_paths::TASK_BOARD_MACHINES,
            get(get_task_board_machines),
        )
        .merge(task_board_host_routes());
    let router = merge_orchestrator_routes(router);
    router
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES,
            get(get_task_board_policy_canvas_workspace),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_CREATE,
            post(post_task_board_policy_canvas_create),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_DUPLICATE,
            post(post_task_board_policy_canvas_duplicate),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_RENAME,
            post(post_task_board_policy_canvas_rename),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_ACTIVE,
            post(post_task_board_policy_canvas_set_active),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_DELETE,
            post(post_task_board_policy_canvas_delete),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_PIPELINE,
            get(get_task_board_policy_pipeline).put(put_task_board_policy_pipeline_draft),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_SIMULATE,
            post(post_task_board_policy_simulate),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_PROMOTE,
            post(post_task_board_policy_promote),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_AUDIT,
            get(get_task_board_policy_audit),
        )
}

async fn get_task_board_policy_pipeline(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<TaskBoardPolicyPipelineGetRequest>,
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
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        pipeline,
    )
}

async fn get_task_board_policy_canvas_workspace(
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
        http_paths::TASK_BOARD_POLICY_CANVASES,
        &request_id,
        start,
        workspace,
    )
}

async fn post_task_board_policy_canvas_create(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasCreateRequest>,
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
        http_paths::TASK_BOARD_POLICY_CANVASES_CREATE,
        &request_id,
        start,
        workspace,
    )
}

async fn post_task_board_policy_canvas_duplicate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasDuplicateRequest>,
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
        http_paths::TASK_BOARD_POLICY_CANVASES_DUPLICATE,
        &request_id,
        start,
        workspace,
    )
}

async fn post_task_board_policy_canvas_rename(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasRenameRequest>,
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
        http_paths::TASK_BOARD_POLICY_CANVASES_RENAME,
        &request_id,
        start,
        workspace,
    )
}

async fn post_task_board_policy_canvas_set_active(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasSetActiveRequest>,
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
        http_paths::TASK_BOARD_POLICY_CANVASES_ACTIVE,
        &request_id,
        start,
        workspace,
    )
}

async fn post_task_board_policy_canvas_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasDeleteRequest>,
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
        http_paths::TASK_BOARD_POLICY_CANVASES_DELETE,
        &request_id,
        start,
        workspace,
    )
}

async fn put_task_board_policy_pipeline_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSaveDraftRequest>,
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
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        pipeline,
    )
}

async fn post_task_board_policy_simulate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSimulateRequest>,
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
        http_paths::TASK_BOARD_POLICY_SIMULATE,
        &request_id,
        start,
        pipeline,
    )
}

async fn post_task_board_policy_promote(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelinePromoteRequest>,
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
        http_paths::TASK_BOARD_POLICY_PROMOTE,
        &request_id,
        start,
        pipeline,
    )
}

async fn get_task_board_policy_audit(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<TaskBoardPolicyPipelineAuditRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let audit = match require_async_db(&state, "policy pipeline audit") {
        Ok(db) => task_board_route_executor::audit_policy_pipeline(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_AUDIT,
        &request_id,
        start,
        audit,
    )
}
