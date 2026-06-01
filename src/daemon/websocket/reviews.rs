use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    ReviewTarget, ReviewsActionPreviewRequest, ReviewsApproveRequest, ReviewsAutoRequest,
    ReviewsAvatarRequest, ReviewsBodyRequest, ReviewsBodyUpdateRequest, ReviewsCommentRequest,
    ReviewsFileCommentRequest, ReviewsFilesBlobRequest, ReviewsFilesListRequest,
    ReviewsFilesPatchRequest, ReviewsFilesPreviewRequest, ReviewsFilesViewedRequest,
    ReviewsLabelRequest, ReviewsMergeRequest, ReviewsPolicyHistoryRequest,
    ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest, ReviewsPolicyStatusRequest,
    ReviewsQueryRequest, ReviewsRefreshRequest, ReviewsRepositoryCatalogRequest,
    ReviewsRequestReviewRequest, ReviewsRerunChecksRequest, ReviewsReviewThreadResolveRequest,
    ReviewsTimelineRequest, WsRequest, WsResponse, ws_methods,
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
    state: &DaemonHttpState,
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
        ws_methods::REVIEWS_POLICY_START => {
            Some(dispatch_reviews_policy_start(request, state).await)
        }
        ws_methods::REVIEWS_POLICY_STATUS => Some(dispatch_reviews_policy_status(request)),
        ws_methods::REVIEWS_POLICY_HISTORY => Some(dispatch_reviews_policy_history(request)),
        ws_methods::REVIEWS_APPROVE => Some(dispatch_reviews_approve(request, state).await),
        ws_methods::REVIEWS_MERGE => Some(dispatch_reviews_merge(request, state).await),
        ws_methods::REVIEWS_RERUN_CHECKS => {
            Some(dispatch_reviews_rerun_checks(request, state).await)
        }
        ws_methods::REVIEWS_ADD_LABEL => Some(dispatch_reviews_add_label(request, state).await),
        ws_methods::REVIEWS_AUTO => Some(dispatch_reviews_auto(request).await),
        ws_methods::REVIEWS_REQUEST_REVIEW => {
            Some(dispatch_reviews_request_review(request, state).await)
        }
        ws_methods::REVIEWS_CLEAR_CACHE => Some(dispatch_query_result(
            &request.id,
            service::clear_reviews_caches_with_timeline(),
        )),
        ws_methods::REVIEWS_REFRESH => Some(dispatch_reviews_refresh(request).await),
        ws_methods::REVIEWS_BODY => Some(dispatch_reviews_body(request).await),
        ws_methods::REVIEWS_BODY_UPDATE => Some(dispatch_reviews_body_update(request, state).await),
        ws_methods::REVIEWS_COMMENT => Some(dispatch_reviews_comment(request, state).await),
        ws_methods::REVIEWS_FILES_LIST => Some(dispatch_reviews_files_list(request).await),
        ws_methods::REVIEWS_FILES_PATCH => Some(dispatch_reviews_files_patch(request).await),
        ws_methods::REVIEWS_FILES_PREVIEW => Some(dispatch_reviews_files_preview(request).await),
        ws_methods::REVIEWS_FILES_VIEWED => {
            Some(dispatch_reviews_files_viewed(request, state).await)
        }
        ws_methods::REVIEWS_FILES_BLOB => Some(dispatch_reviews_files_blob(request).await),
        ws_methods::REVIEWS_FILES_COMMENT => {
            Some(dispatch_reviews_files_comment(request, state).await)
        }
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
            Some(dispatch_reviews_review_threads_resolve(request, state).await)
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

async fn dispatch_reviews_policy_start(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPolicyRunStartRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::start_reviews_policy_run_with_audit_db(&body, state.async_db.get().cloned()).await,
    )
}

fn dispatch_reviews_policy_status(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPolicyStatusRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::reviews_policy_status(&body))
}

fn dispatch_reviews_policy_history(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPolicyHistoryRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::reviews_policy_history(&body))
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

async fn dispatch_reviews_approve(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsApproveRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::approve_reviews(&body).await;
    record_reviews_audit_result(
        state,
        "reviews.approve",
        "Approve pull request",
        &body.targets,
        serde_json::json!({ "target_count": body.targets.len() }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_reviews_merge(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsMergeRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::merge_reviews(&body).await;
    record_reviews_audit_result(
        state,
        "reviews.merge",
        "Merge pull request",
        &body.targets,
        serde_json::json!({
            "target_count": body.targets.len(),
            "method": format!("{:?}", body.method),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_reviews_rerun_checks(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsRerunChecksRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::rerun_reviews_checks(&body).await;
    record_reviews_audit_result(
        state,
        "reviews.rerun_checks",
        "Rerun pull request checks",
        &body.targets,
        serde_json::json!({ "target_count": body.targets.len() }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_reviews_add_label(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsLabelRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::add_label_to_reviews(&body).await;
    record_reviews_audit_result(
        state,
        "reviews.add_label",
        "Add pull request label",
        &body.targets,
        serde_json::json!({
            "target_count": body.targets.len(),
            "label": body.label,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_reviews_auto(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsAutoRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::auto_reviews(&body).await)
}

async fn dispatch_reviews_request_review(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsRequestReviewRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::request_review_for_reviews(&body).await;
    record_reviews_audit_result(
        state,
        "reviews.request_review",
        "Request pull request review",
        &body.targets,
        serde_json::json!({
            "target_count": body.targets.len(),
            "reviewer_login": body.reviewer_login,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
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

async fn dispatch_reviews_body_update(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsBodyUpdateRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::update_review_body(&body).await;
    record_github_audit_result(
        state,
        "reviews.body_update",
        "Update pull request body",
        Some(body.pull_request_id.clone()),
        serde_json::json!({
            "pull_request_id": body.pull_request_id,
            "expected_prior_body_sha256": body.expected_prior_body_sha256,
            "new_body_length": body.new_body.chars().count(),
        }),
        Vec::new(),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_reviews_comment(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsCommentRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::comment_on_reviews(&body).await;
    record_reviews_audit_result(
        state,
        "reviews.comment",
        "Comment on pull request",
        &body.targets,
        serde_json::json!({
            "target_count": body.targets.len(),
            "body_length": body.body.chars().count(),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
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

async fn dispatch_reviews_files_viewed(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesViewedRequest>(request) else {
        return invalid_params(request);
    };
    let mark_viewed_count = body
        .paths
        .iter()
        .filter(|target| target.mark_viewed)
        .count();
    let result = service::mark_review_files_viewed(&body).await;
    record_github_audit_result(
        state,
        "reviews.files_viewed",
        "Update pull request file viewed state",
        Some(body.pull_request_id.clone()),
        serde_json::json!({
            "pull_request_id": body.pull_request_id,
            "path_count": body.paths.len(),
            "mark_viewed_count": mark_viewed_count,
        }),
        Vec::new(),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_reviews_files_blob(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFilesBlobRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::fetch_review_file_blob(&body).await)
}

async fn dispatch_reviews_files_comment(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsFileCommentRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::add_review_file_comment(&body).await;
    record_github_audit_result(
        state,
        "reviews.file_comment",
        "Comment on pull request file",
        Some(body.pull_request_id.clone()),
        serde_json::json!({
            "pull_request_id": body.pull_request_id,
            "repository": body.repository,
            "kind": body.kind,
            "body_length": body.body.chars().count(),
            "path": body.path,
            "line": body.line,
            "thread_id": body.thread_id,
        }),
        Vec::new(),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
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

async fn dispatch_reviews_review_threads_resolve(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsReviewThreadResolveRequest>(request) else {
        return invalid_params(request);
    };
    let result = service::set_review_thread_resolved(&body).await;
    record_github_audit_result(
        state,
        "reviews.review_thread_resolve",
        "Update pull request review thread resolution",
        Some(body.pull_request_id.clone()),
        serde_json::json!({
            "pull_request_id": body.pull_request_id,
            "thread_id": body.thread_id,
            "resolved": body.resolved,
        }),
        Vec::new(),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid params")
}

async fn record_reviews_audit_result<T>(
    state: &DaemonHttpState,
    action_key: &'static str,
    title: &'static str,
    targets: &[ReviewTarget],
    payload_json: serde_json::Value,
    result: &Result<T, crate::errors::CliError>,
) {
    record_github_audit_result(
        state,
        action_key,
        title,
        review_targets_subject(targets),
        payload_json,
        targets.iter().map(|target| target.url.clone()).collect(),
        result,
    )
    .await;
}

async fn record_github_audit_result<T>(
    state: &DaemonHttpState,
    action_key: &'static str,
    title: &'static str,
    subject: Option<String>,
    payload_json: serde_json::Value,
    related_urls: Vec<String>,
    result: &Result<T, crate::errors::CliError>,
) {
    record_audit_result(
        state.async_db.get(),
        AuditEventDraft {
            source: "github",
            category: "githubMutation",
            kind: action_key,
            action_key,
            title: title.to_owned(),
            subject,
            actor: Some("Harness Monitor".to_owned()),
            payload_json: Some(payload_json),
            related_urls,
        },
        result,
    )
    .await;
}

fn review_targets_subject(targets: &[ReviewTarget]) -> Option<String> {
    let first = targets.first()?;
    let subject = format!("{}#{}", first.repository, first.number);
    if targets.len() == 1 {
        return Some(subject);
    }
    Some(format!("{subject} +{}", targets.len() - 1))
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
