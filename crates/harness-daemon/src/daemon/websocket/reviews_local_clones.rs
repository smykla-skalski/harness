use serde::de::DeserializeOwned;

use crate::daemon::protocol::{WsRequest, WsResponse};
use crate::daemon::service;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

#[derive(serde::Deserialize)]
struct DeleteLocalClonePayload {
    repo_key_segment: String,
}

pub(crate) async fn dispatch_reviews_files_local_clones_delete(request: &WsRequest) -> WsResponse {
    let Ok(payload) = parse_params::<DeleteLocalClonePayload>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::delete_review_local_clone(&payload.repo_key_segment).await,
    )
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid params")
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> Result<T, serde_json::Error> {
    serde_json::from_value(request.params.clone())
}
