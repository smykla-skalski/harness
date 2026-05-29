use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    ReviewsActionPreviewRequest, ReviewsApproveRequest, ReviewsAutoRequest, ReviewsAvatarRequest,
    ReviewsBodyRequest, ReviewsBodyUpdateRequest, ReviewsCommentRequest, ReviewsFileCommentRequest,
    ReviewsFilesBlobRequest, ReviewsFilesListRequest, ReviewsFilesPatchRequest,
    ReviewsFilesPreviewRequest, ReviewsFilesViewedRequest, ReviewsLabelRequest,
    ReviewsMergeRequest, ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest,
    ReviewsPolicyStatusRequest, ReviewsQueryRequest, ReviewsRefreshRequest,
    ReviewsRepositoryCatalogRequest, ReviewsRequestReviewRequest, ReviewsRerunChecksRequest,
    ReviewsReviewThreadResolveRequest, ReviewsTimelineRequest, WsRequest, WsResponse, ws_methods,
};
use crate::daemon::service;
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

#[expect(
    clippy::cognitive_complexity,
    reason = "dependency-update websocket method dispatch is clearer as an explicit match"
)]
pub(crate) async fn dispatch_reviews_method(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::REVIEWS_REPOSITORY_CATALOG => {
            Some(dispatch_reviews_repository_catalog(request).await)
        }
        ws_methods::REVIEWS_CAPABILITIES => Some(dispatch_query_result(
            &request.id,
            service::reviews_capabilities(),
        )),
        ws_methods::REVIEWS_QUERY => Some(dispatch_reviews_query(request).await),
        ws_methods::REVIEWS_ACTION_PREVIEW => Some(dispatch_reviews_action_preview(request)),
        ws_methods::REVIEWS_POLICY_PREVIEW => Some(dispatch_reviews_policy_preview(request)),
        ws_methods::REVIEWS_POLICY_START => Some(dispatch_reviews_policy_start(request).await),
        ws_methods::REVIEWS_POLICY_STATUS => Some(dispatch_reviews_policy_status(request)),
        ws_methods::REVIEWS_APPROVE => Some(dispatch_reviews_approve(request).await),
        ws_methods::REVIEWS_MERGE => Some(dispatch_reviews_merge(request).await),
        ws_methods::REVIEWS_RERUN_CHECKS => Some(dispatch_reviews_rerun_checks(request).await),
        ws_methods::REVIEWS_ADD_LABEL => Some(dispatch_reviews_add_label(request).await),
        ws_methods::REVIEWS_AUTO => Some(dispatch_reviews_auto(request).await),
        ws_methods::REVIEWS_REQUEST_REVIEW => Some(dispatch_reviews_request_review(request).await),
        ws_methods::REVIEWS_CLEAR_CACHE => Some(dispatch_query_result(
            &request.id,
            service::clear_reviews_caches_with_timeline(),
        )),
        ws_methods::REVIEWS_REFRESH => Some(dispatch_reviews_refresh(request).await),
        ws_methods::REVIEWS_BODY => Some(dispatch_reviews_body(request).await),
        ws_methods::REVIEWS_BODY_UPDATE => Some(dispatch_reviews_body_update(request).await),
        ws_methods::REVIEWS_COMMENT => Some(dispatch_reviews_comment(request).await),
        ws_methods::REVIEWS_FILES_LIST => Some(dispatch_reviews_files_list(request).await),
        ws_methods::REVIEWS_FILES_PATCH => Some(dispatch_reviews_files_patch(request).await),
        ws_methods::REVIEWS_FILES_PREVIEW => Some(dispatch_reviews_files_preview(request).await),
        ws_methods::REVIEWS_FILES_VIEWED => Some(dispatch_reviews_files_viewed(request).await),
        ws_methods::REVIEWS_FILES_BLOB => Some(dispatch_reviews_files_blob(request).await),
        ws_methods::REVIEWS_FILES_COMMENT => Some(dispatch_reviews_files_comment(request).await),
        ws_methods::REVIEWS_FILES_LOCAL_CLONES_LIST => Some(dispatch_query_result(
            &request.id,
            service::list_review_local_clones().await,
        )),
        ws_methods::REVIEWS_FILES_LOCAL_CLONES_DELETE => {
            Some(dispatch_reviews_files_local_clones_delete(request).await)
        }
        ws_methods::REVIEWS_AVATAR => Some(dispatch_reviews_avatar(request).await),
        ws_methods::REVIEWS_TIMELINE => Some(dispatch_reviews_timeline(request).await),
        ws_methods::REVIEWS_REVIEW_THREADS_RESOLVE => {
            Some(dispatch_reviews_review_threads_resolve(request).await)
        }
        _ => None,
    }
}

#[derive(serde::Deserialize)]
struct DeleteLocalClonePayload {
    repo_key_segment: String,
}

async fn dispatch_reviews_files_local_clones_delete(request: &WsRequest) -> WsResponse {
    let Ok(payload) = parse_params::<DeleteLocalClonePayload>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::delete_review_local_clone(&payload.repo_key_segment).await,
    )
}

fn dispatch_reviews_action_preview(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsActionPreviewRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::preview_review_action(&body))
}

fn dispatch_reviews_policy_preview(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPolicyPreviewRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::preview_reviews_policy(&body))
}

async fn dispatch_reviews_policy_start(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPolicyRunStartRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::start_reviews_policy_run(&body).await)
}

fn dispatch_reviews_policy_status(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPolicyStatusRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::reviews_policy_status(&body))
}

async fn dispatch_reviews_repository_catalog(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsRepositoryCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::catalog_review_repositories(&body).await,
    )
}

async fn dispatch_reviews_query(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<ReviewsQueryRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::query_reviews(&body).await)
}

async fn dispatch_reviews_approve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsApproveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::approve_reviews(&body).await)
}

async fn dispatch_reviews_merge(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsMergeRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::merge_reviews(&body).await)
}

async fn dispatch_reviews_rerun_checks(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsRerunChecksRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::rerun_reviews_checks(&body).await)
}

async fn dispatch_reviews_add_label(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsLabelRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::add_label_to_reviews(&body).await)
}

async fn dispatch_reviews_auto(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsAutoRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::auto_reviews(&body).await)
}

async fn dispatch_reviews_request_review(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsRequestReviewRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::request_review_for_reviews(&body).await,
    )
}

async fn dispatch_reviews_refresh(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsRefreshRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::refresh_reviews(&body).await)
}

async fn dispatch_reviews_body(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsBodyRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::fetch_review_body(&body).await)
}

async fn dispatch_reviews_body_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsBodyUpdateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::update_review_body(&body).await)
}

async fn dispatch_reviews_comment(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsCommentRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::comment_on_reviews(&body).await)
}

async fn dispatch_reviews_files_list(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesListRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::list_review_files(&body).await)
}

async fn dispatch_reviews_files_patch(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesPatchRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::patch_review_files(&body).await)
}

async fn dispatch_reviews_files_preview(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesPreviewRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::preview_review_files(&body).await)
}

async fn dispatch_reviews_files_viewed(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesViewedRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::mark_review_files_viewed(&body).await)
}

async fn dispatch_reviews_files_blob(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesBlobRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::fetch_review_file_blob(&body).await)
}

async fn dispatch_reviews_files_comment(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFileCommentRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::add_review_file_comment(&body).await)
}

async fn dispatch_reviews_timeline(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsTimelineRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::fetch_review_timeline(&body).await)
}

async fn dispatch_reviews_avatar(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsAvatarRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::fetch_review_avatar(&body).await)
}

async fn dispatch_reviews_review_threads_resolve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsReviewThreadResolveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::set_review_thread_resolved(&body).await,
    )
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid params")
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> Result<T, serde_json::Error> {
    serde_json::from_value(request.params.clone())
}

fn parse_params_or_default<T>(request: &WsRequest) -> Result<T, serde_json::Error>
where
    T: DeserializeOwned + Default,
{
    if request.params.is_null() {
        Ok(T::default())
    } else {
        parse_params(request)
    }
}
