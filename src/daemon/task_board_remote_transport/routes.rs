use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, Method, StatusCode};
use axum::response::Response;
use axum::Json;
use utoipa_axum::router::{OpenApiRouter, UtoipaMethodRouterExt};
use utoipa_axum::routes;

use super::routes_status::{mutation_record, status_response, verify_operation_record};
use super::routes_support::{
    active_assignments, assignment_route, concurrent, load_assignment, local_host, map_route_error,
    map_route_result, offer_response, record_lease, route_error, verify_route_identity, wire_error,
};
use super::wire::{
    RemoteArtifactFetchRequest, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteLeaseRenewRequest, RemoteLeaseRenewResponse, RemoteOfferRequest, RemoteSettledRequest,
    RemoteSourceBundleUploadRequest, RemoteStatusRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use super::wire_conversion::host_wire_advertisement;
use super::wire_limits::{
    MAX_REMOTE_LIFECYCLE_JSON_BYTES, MAX_REMOTE_OFFER_JSON_BYTES,
    MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES, MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES,
};
use crate::daemon::db::utc_now;
use crate::daemon::http::{DaemonHttpState, require_async_db, require_execution_remote_client};
use crate::daemon::http::openapi::DaemonErrorBody;
use harness_kernel::errors::CliErrorKind;
use super::wire::{
    RemoteArtifactFetchResponse, RemoteClaimResponse, RemoteHostAdvertisement, RemoteOfferResponse,
    RemoteSettledResponse, RemoteSourceBundleUploadResponse, RemoteStatusResponse,
};

pub(crate) const ADVERTISE_PATH: &str = "/v1/task-board-execution/advertise";
pub(crate) const OFFER_PATH: &str = "/v1/task-board-execution/offers";
pub(crate) const CLAIM_PATH: &str = "/v1/task-board-execution/claims";
pub(crate) const LEASE_RENEW_PATH: &str = "/v1/task-board-execution/leases/renew";
pub(crate) const STATUS_PATH: &str = "/v1/task-board-execution/status";
pub(crate) const CANCEL_PATH: &str = "/v1/task-board-execution/cancel";
pub(crate) const SETTLED_PATH: &str = "/v1/task-board-execution/settled";
pub(crate) const ARTIFACT_PATH: &str = "/v1/task-board-execution/artifacts/fetch";
pub(crate) const SOURCE_BUNDLE_PATH: &str = "/v1/task-board-execution/source-bundles/upload";
pub(crate) const SOURCE_BUNDLE_RECEIPT_PATH: &str =
    "/v1/task-board-execution/source-bundles/receipt";
pub(crate) const SOURCE_BUNDLE_ABANDON_PATH: &str =
    "/v1/task-board-execution/source-bundles/abandon";
pub(crate) const OFFER_HTTP_BODY_LIMIT_BYTES: usize = MAX_REMOTE_OFFER_JSON_BYTES;
pub(crate) const SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES: usize = MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES;
pub(crate) const SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES: usize =
    MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES;
pub(crate) const DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES: usize = MAX_REMOTE_LIFECYCLE_JSON_BYTES;
pub(crate) const MAX_EXECUTION_HTTP_BODY_LIMIT_BYTES: usize = max_body_limit(
    max_body_limit(
        SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES,
        SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES,
    ),
    max_body_limit(
        OFFER_HTTP_BODY_LIMIT_BYTES,
        DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES,
    ),
);

const fn max_body_limit(left: usize, right: usize) -> usize {
    if left > right { left } else { right }
}

fn execution_offer_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(offer).layer(DefaultBodyLimit::max(OFFER_HTTP_BODY_LIMIT_BYTES)))
        .routes(
            routes!(upload_source_bundle)
                .layer(DefaultBodyLimit::max(SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES)),
        )
        .routes(
            routes!(super::routes_source_bundle::verify_source_bundle_receipt)
                .layer(DefaultBodyLimit::max(SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES)),
        )
        .routes(
            routes!(super::routes_source_bundle::abandon_source_bundle).layer(
                DefaultBodyLimit::max(SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES),
            ),
        )
}

fn execution_attempt_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(claim).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)))
        .routes(routes!(renew_lease).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)))
        .routes(routes!(status).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)))
        .routes(routes!(cancel).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)))
        .routes(routes!(settled).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)))
}

fn execution_result_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(
            routes!(fetch_artifact).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .routes(
            routes!(super::routes_cleanup::observe_cleanup)
                .layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
}

pub(crate) fn execution_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(advertise))
        .merge(execution_offer_routes())
        .merge(execution_attempt_routes())
        .merge(execution_result_routes())
}

pub(crate) fn execution_http_body_limit(method: &Method, path: &str) -> Option<usize> {
    match (method, path) {
        (&Method::POST, SOURCE_BUNDLE_PATH | SOURCE_BUNDLE_RECEIPT_PATH) => {
            Some(SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES)
        }
        (&Method::POST, SOURCE_BUNDLE_ABANDON_PATH) => {
            Some(SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES)
        }
        (&Method::POST, OFFER_PATH) => Some(OFFER_HTTP_BODY_LIMIT_BYTES),
        (
            &Method::POST,
            CLAIM_PATH
            | LEASE_RENEW_PATH
            | STATUS_PATH
            | CANCEL_PATH
            | SETTLED_PATH
            | ARTIFACT_PATH
            | super::routes_cleanup::CLEANUP_OBSERVATION_PATH,
        ) => Some(DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES),
        _ => None,
    }
}

/// Every remote-execution transport operation as `(method, path,
/// operation_id)`. The auth recognizer ([`execution_operation`]) and the
/// `OpenAPI` contract test both read this table, so a documented transport route
/// cannot drift from the recognized set. Re-exported under `http::openapi`;
/// the transport module itself stays crate-internal.
pub const EXECUTION_OPERATIONS: &[(Method, &str, &str)] = &[
    (Method::GET, ADVERTISE_PATH, "advertise"),
    (Method::POST, OFFER_PATH, "offer"),
    (Method::POST, SOURCE_BUNDLE_PATH, "upload_source_bundle"),
    (
        Method::POST,
        SOURCE_BUNDLE_RECEIPT_PATH,
        "verify_source_bundle_receipt",
    ),
    (
        Method::POST,
        SOURCE_BUNDLE_ABANDON_PATH,
        "abandon_source_bundle",
    ),
    (Method::POST, CLAIM_PATH, "claim"),
    (Method::POST, LEASE_RENEW_PATH, "renew_lease"),
    (Method::POST, STATUS_PATH, "status"),
    (Method::POST, CANCEL_PATH, "cancel"),
    (Method::POST, SETTLED_PATH, "settled"),
    (Method::POST, ARTIFACT_PATH, "fetch_artifact"),
    (
        Method::POST,
        super::routes_cleanup::CLEANUP_OBSERVATION_PATH,
        "observe_cleanup",
    ),
];

/// Recognise a remote-execution transport route, returning its operation id.
#[must_use]
pub fn execution_operation(method: &Method, path: &str) -> Option<&'static str> {
    EXECUTION_OPERATIONS
        .iter()
        .find(|entry| entry.0 == *method && entry.1 == path)
        .map(|entry| entry.2)
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/source-bundles/upload",
    tag = "task-board-execution",
    description = "Store a source-bundle upload for a claimed assignment. Requires a remote-executor client credential whose client id matches the assignment binding's host id",
    request_body = RemoteSourceBundleUploadRequest,
    responses(
        (status = 200, description = "Stored source-bundle receipt", body = RemoteSourceBundleUploadResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn upload_source_bundle(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteSourceBundleUploadRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) = assignment_route(
                &headers,
                &state,
                "upload_source_bundle",
                &request.offer.binding,
            )
            .await?;
            Ok(db
                .store_task_board_remote_source_bundle(
                    &request,
                    &principal,
                    &state.daemon_epoch,
                    &utc_now(),
                )
                .await?
                .response)
        }
        .await,
    )
}

#[utoipa::path(
    get,
    path = "/v1/task-board-execution/advertise",
    tag = "task-board-execution",
    description = "Advertise the local execution host's identity and its active assignment bindings to a remote-executor client. Requires a remote-executor client credential and fails if the local execution host is disabled",
    responses(
        (status = 200, description = "Execution host identity and its active assignment bindings", body = RemoteHostAdvertisement),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn advertise(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    map_route_result(
        async {
            let db = require_async_db(&state, "advertise remote execution host")?;
            let host = local_host(db).await?;
            let client =
                require_execution_remote_client(&headers, &state, "advertise").map_err(|_| {
                    CliErrorKind::session_permission_denied("remote executor authorization denied")
                })?;
            verify_route_identity(&host, &state.daemon_epoch, &client.client_id, None)?;
            let active = active_assignments(db, &host).await?;
            host_wire_advertisement(&host, &state.daemon_epoch, active, utc_now())
                .map_err(|error| wire_error(&error))
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/offers",
    tag = "task-board-execution",
    description = "Accept or reject an assignment offer for a remote executor, returning the disposition and, when accepted, the assignment lease",
    request_body = RemoteOfferRequest,
    responses(
        (status = 200, description = "Offer disposition and, when accepted, the assignment lease", body = RemoteOfferResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn offer(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteOfferRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) =
                assignment_route(&headers, &state, "offer", &request.binding).await?;
            let outcome = db
                .accept_task_board_remote_assignment_offer(
                    &request,
                    &principal,
                    &state.daemon_epoch,
                    &utc_now(),
                )
                .await?;
            offer_response(outcome, &request)
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/claims",
    tag = "task-board-execution",
    description = "Claim an offered assignment, returning its immutable claim receipt. A claim against a stale daemon epoch is rejected unless the assignment already has a receipt, so a retry against an already-claimed assignment can still succeed idempotently",
    request_body = RemoteClaimRequest,
    responses(
        (status = 200, description = "Immutable claim receipt for the assignment", body = RemoteClaimResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn claim(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteClaimRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) =
                assignment_route(&headers, &state, "claim", &request.binding).await?;
            let _ = mutation_record(
                db.claim_task_board_remote_assignment(&request, &principal, &utc_now())
                    .await?,
            )?;
            db.exact_task_board_remote_claim_receipt(&request, &principal)
                .await?
                .map(|(response, _)| response)
                .ok_or_else(|| concurrent("remote claim completed without an immutable receipt"))
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/leases/renew",
    tag = "task-board-execution",
    description = "Renew the lease on a claimed assignment, extending its expiry so the remote executor can keep working it",
    request_body = RemoteLeaseRenewRequest,
    responses(
        (status = 200, description = "Renewed lease for the claimed assignment", body = RemoteLeaseRenewResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn renew_lease(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteLeaseRenewRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) =
                assignment_route(&headers, &state, "renew_lease", &request.binding).await?;
            let record = mutation_record(
                db.renew_task_board_remote_assignment_lease(&request, &principal, &utc_now())
                    .await?,
            )?;
            Ok(RemoteLeaseRenewResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: request.binding,
                offer_request_sha256: request.offer_request_sha256,
                lease: record_lease(&record)?,
            })
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/status",
    tag = "task-board-execution",
    description = "Report the authoritative status of a claimed assignment, after verifying the request's lease id and offer hash match the stored assignment record",
    request_body = RemoteStatusRequest,
    responses(
        (status = 200, description = "Authoritative status of the claimed assignment", body = RemoteStatusResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteStatusRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) =
                assignment_route(&headers, &state, "status", &request.binding).await?;
            let record = load_assignment(db, &request.binding.assignment_id).await?;
            verify_operation_record(
                &record,
                &request.binding,
                &request.lease_id,
                &request.offer_request_sha256,
                &principal,
            )?;
            status_response(&record, &request)
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/cancel",
    tag = "task-board-execution",
    description = "Cancel a claimed assignment, returning the terminal cancellation record for it",
    request_body = RemoteCancelRequest,
    responses(
        (status = 200, description = "Terminal cancellation record for the assignment", body = RemoteCancelResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn cancel(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteCancelRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) =
                assignment_route(&headers, &state, "cancel", &request.binding).await?;
            let record = mutation_record(
                db.cancel_task_board_remote_assignment(&request, &principal, &utc_now())
                    .await?,
            )?;
            RemoteCancelResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: request.binding.clone(),
                offer_request_sha256: request.offer_request_sha256.clone(),
                cancel_response_sha256: String::new(),
                state: record.wire_state(),
                claimed_at: record.claimed_at.clone(),
                started_at: record.started_at.clone(),
                workspace_ref: record.workspace_ref.clone(),
                observed_at: record.updated_at,
            }
            .seal(&request)
            .map_err(|error| wire_error(&error))
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/settled",
    tag = "task-board-execution",
    description = "Report final settlement for a completed assignment, returning its settlement record",
    request_body = RemoteSettledRequest,
    responses(
        (status = 200, description = "Settlement record for the completed assignment", body = RemoteSettledResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn settled(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteSettledRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(|error| wire_error(&error))?;
            let (db, principal) =
                assignment_route(&headers, &state, "settled", &request.binding).await?;
            Ok(db
                .settle_task_board_remote_assignment(&request, &principal, &utc_now())
                .await?
                .response)
        }
        .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board-execution/artifacts/fetch",
    tag = "task-board-execution",
    description = "Fetch a stored result artifact for an assignment. Responds 503 with the REMOTE_ARTIFACT_UNAVAILABLE code when the executor's artifact storage is unavailable",
    request_body = RemoteArtifactFetchRequest,
    responses(
        (status = 200, description = "Requested result artifact", body = RemoteArtifactFetchResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn fetch_artifact(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteArtifactFetchRequest>,
) -> Response {
    let result = async {
        request.validate().map_err(|error| wire_error(&error))?;
        let (db, principal) =
            assignment_route(&headers, &state, "fetch_artifact", &request.binding).await?;
        db.task_board_remote_artifact(&request, &principal)
            .await?
            .map(|artifact| artifact.response(&request))
            .transpose()
    }
    .await;
    match result {
        Ok(Some(response)) => map_route_result(Ok(response)),
        Ok(None) => route_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "REMOTE_ARTIFACT_UNAVAILABLE",
            "remote executor artifact storage is unavailable",
        ),
        Err(error) => map_route_error(&error),
    }
}
