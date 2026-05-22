use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    DependencyUpdatesActionPreviewRequest, DependencyUpdatesApproveRequest,
    DependencyUpdatesAutoRequest, DependencyUpdatesBodyRequest, DependencyUpdatesBodyUpdateRequest,
    DependencyUpdatesCommentRequest, DependencyUpdatesFilesBlobRequest,
    DependencyUpdatesFilesListRequest, DependencyUpdatesFilesPatchRequest,
    DependencyUpdatesFilesViewedRequest, DependencyUpdatesLabelRequest,
    DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest, DependencyUpdatesRefreshRequest,
    DependencyUpdatesRepositoryCatalogRequest, DependencyUpdatesRerunChecksRequest,
    DependencyUpdatesTimelineRequest, WsRequest, WsResponse, ws_methods,
};
use crate::daemon::service;
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

#[expect(
    clippy::cognitive_complexity,
    reason = "dependency-update websocket method dispatch is clearer as an explicit match"
)]
pub(crate) async fn dispatch_dependency_updates_method(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::DEPENDENCY_UPDATES_REPOSITORY_CATALOG => {
            Some(dispatch_dependency_updates_repository_catalog(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_CAPABILITIES => Some(dispatch_query_result(
            &request.id,
            service::dependency_updates_capabilities(),
        )),
        ws_methods::DEPENDENCY_UPDATES_QUERY => {
            Some(dispatch_dependency_updates_query(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_ACTION_PREVIEW => {
            Some(dispatch_dependency_updates_action_preview(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_APPROVE => {
            Some(dispatch_dependency_updates_approve(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_MERGE => {
            Some(dispatch_dependency_updates_merge(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_RERUN_CHECKS => {
            Some(dispatch_dependency_updates_rerun_checks(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_ADD_LABEL => {
            Some(dispatch_dependency_updates_add_label(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_AUTO => {
            Some(dispatch_dependency_updates_auto(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_CLEAR_CACHE => Some(dispatch_query_result(
            &request.id,
            service::clear_dependency_updates_caches_with_timeline(),
        )),
        ws_methods::DEPENDENCY_UPDATES_REFRESH => {
            Some(dispatch_dependency_updates_refresh(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_BODY => {
            Some(dispatch_dependency_updates_body(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_BODY_UPDATE => {
            Some(dispatch_dependency_updates_body_update(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_COMMENT => {
            Some(dispatch_dependency_updates_comment(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_FILES_LIST => {
            Some(dispatch_dependency_updates_files_list(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_FILES_PATCH => {
            Some(dispatch_dependency_updates_files_patch(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_FILES_VIEWED => {
            Some(dispatch_dependency_updates_files_viewed(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_FILES_BLOB => {
            Some(dispatch_dependency_updates_files_blob(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_LIST => Some(dispatch_query_result(
            &request.id,
            service::list_dependency_update_local_clones().await,
        )),
        ws_methods::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_DELETE => {
            Some(dispatch_dependency_updates_files_local_clones_delete(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_TIMELINE => {
            Some(dispatch_dependency_updates_timeline(request).await)
        }
        _ => None,
    }
}

#[derive(serde::Deserialize)]
struct DeleteLocalClonePayload {
    repo_key_segment: String,
}

async fn dispatch_dependency_updates_files_local_clones_delete(
    request: &WsRequest,
) -> WsResponse {
    let Ok(payload) = parse_params::<DeleteLocalClonePayload>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::delete_dependency_update_local_clone(&payload.repo_key_segment).await,
    )
}

async fn dispatch_dependency_updates_action_preview(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesActionPreviewRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::preview_dependency_update_action(&body),
    )
}

async fn dispatch_dependency_updates_repository_catalog(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesRepositoryCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::catalog_dependency_update_repositories(&body).await,
    )
}

async fn dispatch_dependency_updates_query(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<DependencyUpdatesQueryRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::query_dependency_updates(&body).await)
}

async fn dispatch_dependency_updates_approve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesApproveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::approve_dependency_updates(&body).await,
    )
}

async fn dispatch_dependency_updates_merge(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesMergeRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::merge_dependency_updates(&body).await)
}

async fn dispatch_dependency_updates_rerun_checks(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesRerunChecksRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::rerun_dependency_updates_checks(&body).await,
    )
}

async fn dispatch_dependency_updates_add_label(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesLabelRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::add_label_to_dependency_updates(&body).await,
    )
}

async fn dispatch_dependency_updates_auto(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesAutoRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::auto_dependency_updates(&body).await)
}

async fn dispatch_dependency_updates_refresh(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesRefreshRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::refresh_dependency_updates(&body).await,
    )
}

async fn dispatch_dependency_updates_body(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesBodyRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::fetch_dependency_update_body(&body).await,
    )
}

async fn dispatch_dependency_updates_body_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesBodyUpdateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::update_dependency_update_body(&body).await,
    )
}

async fn dispatch_dependency_updates_comment(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesCommentRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::comment_on_dependency_updates(&body).await,
    )
}

async fn dispatch_dependency_updates_files_list(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesFilesListRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::list_dependency_update_files(&body).await,
    )
}

async fn dispatch_dependency_updates_files_patch(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesFilesPatchRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::patch_dependency_update_files(&body).await,
    )
}

async fn dispatch_dependency_updates_files_viewed(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesFilesViewedRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::mark_dependency_update_files_viewed(&body).await,
    )
}

async fn dispatch_dependency_updates_files_blob(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesFilesBlobRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::fetch_dependency_update_file_blob(&body).await,
    )
}

async fn dispatch_dependency_updates_timeline(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<DependencyUpdatesTimelineRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::fetch_dependency_update_timeline(&body).await,
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
