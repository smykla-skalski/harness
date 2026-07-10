use serde::de::DeserializeOwned;

use crate::daemon::protocol::{ReviewsPullRequestResolveRequest, WsRequest, WsResponse};
use crate::daemon::service;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

pub(crate) async fn dispatch_reviews_pull_request_resolve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<ReviewsPullRequestResolveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::resolve_review_pull_requests(&body).await,
    )
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid params")
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> Result<T, serde_json::Error> {
    serde_json::from_value(request.params.clone())
}
