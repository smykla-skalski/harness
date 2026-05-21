use std::time::Instant;

use axum::Router;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::get;

use crate::daemon::protocol::http_paths;
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

pub(super) fn openrouter_model_routes() -> Router<DaemonHttpState> {
    Router::new().route(http_paths::OPENROUTER_MODELS, get(get_openrouter_models))
}

async fn get_openrouter_models(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::list_openrouter_models().await;
    timed_json(
        "GET",
        http_paths::OPENROUTER_MODELS,
        &request_id,
        start,
        result,
    )
}
