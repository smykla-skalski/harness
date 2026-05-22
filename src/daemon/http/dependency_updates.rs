use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{delete, get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    DependencyUpdatesActionPreviewRequest, DependencyUpdatesApproveRequest,
    DependencyUpdatesAutoRequest, DependencyUpdatesBodyRequest, DependencyUpdatesBodyUpdateRequest,
    DependencyUpdatesCommentRequest, DependencyUpdatesFilesBlobRequest,
    DependencyUpdatesFilesListRequest, DependencyUpdatesFilesPatchRequest,
    DependencyUpdatesFilesViewedRequest, DependencyUpdatesLabelRequest,
    DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest, DependencyUpdatesRefreshRequest,
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
            http_paths::DEPENDENCY_UPDATES_CAPABILITIES,
            get(get_dependency_update_capabilities),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_QUERY,
            post(post_query_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_ACTION_PREVIEW,
            post(post_dependency_update_action_preview),
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
        .route(
            http_paths::DEPENDENCY_UPDATES_COMMENT,
            post(post_comment_dependency_updates),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_FILES_LIST,
            post(post_dependency_update_files_list),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_FILES_PATCH,
            post(post_dependency_update_files_patch),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_FILES_VIEWED,
            post(post_dependency_update_files_viewed),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_FILES_BLOB,
            post(post_dependency_update_files_blob),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES,
            post(post_dependency_update_files_local_clones),
        )
        .route(
            http_paths::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_DELETE,
            post(post_dependency_update_files_local_clones_delete),
        )
}

async fn get_dependency_update_capabilities(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::DEPENDENCY_UPDATES_CAPABILITIES,
        &request_id,
        start,
        service::dependency_updates_capabilities(),
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

async fn post_dependency_update_action_preview(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesActionPreviewRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_ACTION_PREVIEW,
        &request_id,
        start,
        service::preview_dependency_update_action(&request),
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

async fn post_comment_dependency_updates(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesCommentRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::comment_on_dependency_updates(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_COMMENT,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_files_list(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesFilesListRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::list_dependency_update_files(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_FILES_LIST,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_files_patch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesFilesPatchRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::patch_dependency_update_files(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_FILES_PATCH,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_files_viewed(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesFilesViewedRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::mark_dependency_update_files_viewed(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_FILES_VIEWED,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_files_blob(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DependencyUpdatesFilesBlobRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::fetch_dependency_update_file_blob(&request).await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_FILES_BLOB,
        &request_id,
        start,
        result,
    )
}

async fn post_dependency_update_files_local_clones(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::list_dependency_update_local_clones().await;
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES,
        &request_id,
        start,
        result,
    )
}

#[derive(serde::Deserialize)]
struct DeleteLocalClonePayload {
    repo_key_segment: String,
}

#[derive(serde::Serialize)]
struct DeleteLocalCloneResponseBody {
    clones: Vec<crate::dependency_updates::LocalCloneListEntry>,
}

async fn post_dependency_update_files_local_clones_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(payload): Json<DeleteLocalClonePayload>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::delete_dependency_update_local_clone(&payload.repo_key_segment)
        .await
        .map(|clones| DeleteLocalCloneResponseBody { clones });
    timed_json(
        "POST",
        http_paths::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_DELETE,
        &request_id,
        start,
        result,
    )
}
