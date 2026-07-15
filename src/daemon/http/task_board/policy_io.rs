use axum::Json;
use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;

use crate::daemon::protocol::{
    PolicyCanvasExportRequest, PolicyCanvasImportRequest, PolicyTransferBundle,
    PolicyTransferDumpRequest, PolicyTransferImportRequest, http_paths,
};
use crate::errors::{CliError, CliErrorKind};

use super::super::response::timed_json;
use super::super::{
    DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES, DaemonHttpState, require_async_db,
    task_board_route_executor,
};
use super::authenticated_request;

pub(super) fn merge_policy_io_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    router
        .route(http_paths::POLICY_CANVAS_EXPORT, post(post_policy_export))
        .route(http_paths::POLICY_CANVAS_IMPORT, post(post_policy_import))
        .route(
            http_paths::POLICIES_DUMP,
            post(post_policy_dump)
                .layer(DefaultBodyLimit::max(DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES)),
        )
        .route(
            http_paths::POLICIES_IMPORT,
            post(post_policy_import_batch)
                .layer(DefaultBodyLimit::max(DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES)),
        )
}

pub(super) async fn post_policy_dump(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyTransferDumpRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let import_limit = configured_transfer_limit(&state);
    let dump = match require_async_db(&state, "policy transfer dump") {
        Ok(db) => task_board_route_executor::dump_policy_transfer(db, &request).await,
        Err(error) => Err(error),
    }
    .and_then(|bundle| ensure_importable_dump(bundle, import_limit));
    timed_json("POST", http_paths::POLICIES_DUMP, &request_id, start, dump)
}

fn configured_transfer_limit(state: &DaemonHttpState) -> usize {
    state
        .remote_request_limits
        .as_ref()
        .map_or(DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES, |limits| {
            limits
                .config()
                .max_http_body_bytes
                .min(DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES)
        })
}

fn ensure_importable_dump(
    bundle: PolicyTransferBundle,
    limit: usize,
) -> Result<PolicyTransferBundle, CliError> {
    let envelope = PolicyTransferImportRequest {
        bundle: bundle.clone(),
        replace_all: false,
    };
    let size = serde_json::to_vec(&envelope)
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!("failed to size policy transfer dump: {error}"))
        })?
        .len();
    if size > limit {
        return Err(CliErrorKind::invalid_transition(format!(
            "policy transfer dump requires {size} bytes, exceeding the {limit}-byte single-import limit; dump fewer policies with --canvas-id"
        ))
        .into());
    }
    Ok(bundle)
}

pub(super) async fn post_policy_export(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasExportRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let export = match require_async_db(&state, "policy export") {
        Ok(db) => task_board_route_executor::export_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVAS_EXPORT,
        &request_id,
        start,
        export,
    )
}

pub(super) async fn post_policy_import(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasImportRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let import = match require_async_db(&state, "policy import") {
        Ok(db) => task_board_route_executor::import_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVAS_IMPORT,
        &request_id,
        start,
        import,
    )
}

pub(super) async fn post_policy_import_batch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyTransferImportRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let import = match require_async_db(&state, "policy transfer import") {
        Ok(db) => task_board_route_executor::import_policy_transfer(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICIES_IMPORT,
        &request_id,
        start,
        import,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::protocol::{POLICY_TRANSFER_FORMAT, POLICY_TRANSFER_VERSION};
    use crate::task_board::policy_graph::PolicyCanvasWorkspace;

    #[test]
    fn dump_size_guard_accepts_exact_limit_and_rejects_one_byte_less() {
        let policy = PolicyCanvasWorkspace::seeded()
            .canvases
            .into_iter()
            .next()
            .expect("seeded policy");
        let bundle = PolicyTransferBundle {
            format: POLICY_TRANSFER_FORMAT.to_string(),
            version: POLICY_TRANSFER_VERSION,
            policies: vec![policy],
            workspace: None,
        };
        let envelope = PolicyTransferImportRequest {
            bundle: bundle.clone(),
            replace_all: false,
        };
        let size = serde_json::to_vec(&envelope)
            .expect("serialize import envelope")
            .len();

        assert!(ensure_importable_dump(bundle.clone(), size).is_ok());
        assert!(ensure_importable_dump(bundle, size - 1).is_err());
    }
}
