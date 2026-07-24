use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use crate::daemon::protocol::http_paths;
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

use super::openapi::DaemonErrorBody;
use crate::daemon::protocol::OpenRouterModelCatalogResponse;

pub(super) fn openrouter_model_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new().routes(routes!(get_openrouter_models))
}

#[utoipa::path(
    get,
    path = "/v1/openrouter/models",
    tag = "daemon",
    responses(
        (status = 200, description = "OpenRouter model catalog", body = OpenRouterModelCatalogResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
