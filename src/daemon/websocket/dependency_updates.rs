use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    DependencyUpdatesApproveRequest, DependencyUpdatesAutoRequest, DependencyUpdatesLabelRequest,
    DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest,
    DependencyUpdatesRerunChecksRequest, WsRequest, WsResponse, ws_methods,
};
use crate::daemon::service;
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

pub(crate) async fn dispatch_dependency_updates_method(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::DEPENDENCY_UPDATES_QUERY => Some(dispatch_dependency_updates_query(request).await),
        ws_methods::DEPENDENCY_UPDATES_APPROVE => {
            Some(dispatch_dependency_updates_approve(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_MERGE => Some(dispatch_dependency_updates_merge(request).await),
        ws_methods::DEPENDENCY_UPDATES_RERUN_CHECKS => {
            Some(dispatch_dependency_updates_rerun_checks(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_ADD_LABEL => {
            Some(dispatch_dependency_updates_add_label(request).await)
        }
        ws_methods::DEPENDENCY_UPDATES_AUTO => Some(dispatch_dependency_updates_auto(request).await),
        ws_methods::DEPENDENCY_UPDATES_CLEAR_CACHE => {
            Some(dispatch_query_result(&request.id, service::clear_dependency_updates_cache()))
        }
        _ => None,
    }
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
    dispatch_query_result(&request.id, service::approve_dependency_updates(&body).await)
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
