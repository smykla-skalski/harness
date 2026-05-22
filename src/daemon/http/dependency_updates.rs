use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{delete, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    DependencyUpdatesApproveRequest, DependencyUpdatesAutoRequest, DependencyUpdatesBodyRequest,
    DependencyUpdatesBodyUpdateRequest, DependencyUpdatesLabelRequest, DependencyUpdatesMergeRequest,
    DependencyUpdatesQueryRequest, DependencyUpdatesRefreshRequest,
    DependencyUpdatesRepositoryCatalogRequest, DependencyUpdatesRerunChecksRequest, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

macro_rules! authenticated_request {
    ($headers:expr, $state:expr) => {{
        let start = Instant::now();
        let request_id = extract_request_id(&$headers);
        if let Err(response) = require_auth(&$headers, &$state) {
            return *response;
        }
        (start, request_id)
    }};
}

pub(super) fn dependency_updates_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::DEPENDENCY_UPDATES_REPOSITORIES,
            post(post_dependency_update_repositories),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_QUERY,
            post(post_query_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_APPROVE,
            post(post_approve_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_MERGE,
            post(post_merge_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_RERUN_CHECKS,
            post(post_rerun_dependency_updates_checks),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_LABELS,
            post(post_label_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_AUTO,
            post(post_auto_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_CACHE,
            delete(delete_dependency_updates_cache),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_REFRESH,
            post(post_refresh_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_BODY,
            post(post_dependency_update_body),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_BODY_UPDATE,
            post(post_dependency_update_body_update),
        )
}

async fn post_dependency_update_repositories(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesRepositoryCatalogRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::catalog_dependency_update_repositories(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_REPOSITORIES,
        &request_id,
        start,
        result,
    )
}

async fn post_query_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesQueryRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::query_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_QUERY,
        &request_id,
        start,
        result,
    )
}

async fn post_approve_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesApproveRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::approve_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_APPROVE,
        &request_id,
        start,
        result,
    )
}

async fn post_merge_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesMergeRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::merge_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_MERGE,
        &request_id,
        start,
        result,
    )
}

async fn post_rerun_dependency_updates_checks(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesRerunChecksRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::rerun_dependency_updates_checks(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_RERUN_CHECKS,
        &request_id,
        start,
        result,
    )
}

async fn post_label_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesLabelRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::add_label_to_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_LABELS,
        &request_id,
        start,
        result,
    )
}

async fn post_auto_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesAutoRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::auto_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_AUTO,
        &request_id,
        start,
        result,
    )
}

async fn delete_dependency_updates_cache(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "DELETE",
        http_paths::DEPENDENCY_UPDATES_CACHE,
        &request_id,
        start,
        service::clear_dependency_updates_cache(),
    )
}

async fn post_refresh_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesRefreshRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::refresh_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_REFRESH,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_body(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesBodyRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::fetch_dependency_update_body(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_BODY,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_body_update(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesBodyUpdateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::update_dependency_update_body(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_BODY_UPDATE,
        &request_id,
        start,
        result,
    )
}
