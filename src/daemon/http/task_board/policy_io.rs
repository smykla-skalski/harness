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
    DaemonHttpAuthMode, DaemonHttpState, require_async_db, task_board_route_executor,
};
use super::authenticated_request;

pub(super) fn merge_policy_io_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    // Remote requests are bounded by the runtime-configured body middleware
    // before extraction; local daemon requests intentionally ignore remote limits.
    router
        .route(http_paths::POLICY_CANVAS_EXPORT, post(post_policy_export))
        .route(http_paths::POLICY_CANVAS_IMPORT, post(post_policy_import))
        .route(
            http_paths::POLICIES_DUMP,
            post(post_policy_dump).layer(DefaultBodyLimit::disable()),
        )
        .route(
            http_paths::POLICIES_IMPORT,
            post(post_policy_import_batch).layer(DefaultBodyLimit::disable()),
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
    if state.auth_mode == DaemonHttpAuthMode::Local {
        return usize::MAX;
    }
    state
        .remote_request_limits
        .as_ref()
        .map_or(usize::MAX, |limits| limits.config().max_http_body_bytes)
}

fn ensure_importable_dump(
    bundle: PolicyTransferBundle,
    limit: usize,
) -> Result<PolicyTransferBundle, CliError> {
    // The boolean is always serialized, and `false` is one byte longer than
    // `true`, so this is the worst-case envelope for either import mode.
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
    use crate::daemon::http::remote_limits::DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES;
    use crate::daemon::http::{RemoteRequestLimitConfig, RemoteRequestLimits};
    use crate::daemon::protocol::{POLICY_TRANSFER_FORMAT, POLICY_TRANSFER_VERSION};
    use crate::task_board::policy_graph::PolicyCanvasWorkspace;

    #[test]
    fn configured_transfer_limit_uses_remote_configuration_and_is_unbounded_locally() {
        let mut state = crate::daemon::http::tests::test_http_state_with_db();
        assert_eq!(configured_transfer_limit(&state), usize::MAX);

        let configured_limit = DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES * 2;
        state.remote_request_limits = Some(
            RemoteRequestLimits::new(RemoteRequestLimitConfig {
                max_http_body_bytes: configured_limit,
                ..RemoteRequestLimitConfig::default()
            })
            .expect("valid remote limits"),
        );
        state.auth_mode = DaemonHttpAuthMode::Remote;

        assert_eq!(configured_transfer_limit(&state), configured_limit);
    }

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
        let replace_all_size = serde_json::to_vec(&PolicyTransferImportRequest {
            bundle: bundle.clone(),
            replace_all: true,
        })
        .expect("serialize replace-all import envelope")
        .len();

        assert_eq!(size, replace_all_size + 1);
        assert!(ensure_importable_dump(bundle.clone(), size).is_ok());
        assert!(ensure_importable_dump(bundle, size - 1).is_err());
    }
}
