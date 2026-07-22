use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, Method, StatusCode};
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{Duration, Utc};

use super::routes_status::{mutation_record, status_response, verify_operation_record};
use super::routes_support::{
    active_assignments, assignment_route, canonical_time, concurrent, load_assignment, local_host,
    map_route_error, map_route_result, offer_response, record_lease, route_error,
    verify_heartbeat_time, verify_route_identity, wire_error,
};
use super::wire::{
    RemoteArtifactFetchRequest, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteHeartbeatRequest, RemoteHeartbeatResponse, RemoteLeaseRenewRequest,
    RemoteLeaseRenewResponse, RemoteOfferRequest, RemoteSettledRequest,
    RemoteSourceBundleUploadRequest, RemoteStatusRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use super::wire_conversion::host_wire_advertisement;
use super::wire_limits::{
    MAX_REMOTE_LIFECYCLE_JSON_BYTES, MAX_REMOTE_OFFER_JSON_BYTES,
    MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES, MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES,
};
use crate::daemon::db::utc_now;
use crate::daemon::http::{DaemonHttpState, require_async_db, require_execution_remote_client};
use crate::task_board::TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS;

pub(crate) const ADVERTISE_PATH: &str = "/v1/task-board-execution/advertise";
pub(crate) const HEARTBEAT_PATH: &str = "/v1/task-board-execution/heartbeat";
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

pub(crate) fn execution_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(ADVERTISE_PATH, get(advertise))
        .route(
            HEARTBEAT_PATH,
            post(heartbeat).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            OFFER_PATH,
            post(offer).layer(DefaultBodyLimit::max(OFFER_HTTP_BODY_LIMIT_BYTES)),
        )
        .route(
            SOURCE_BUNDLE_PATH,
            post(upload_source_bundle)
                .layer(DefaultBodyLimit::max(SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES)),
        )
        .route(
            SOURCE_BUNDLE_RECEIPT_PATH,
            post(super::routes_source_bundle::verify_source_bundle_receipt)
                .layer(DefaultBodyLimit::max(SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES)),
        )
        .route(
            SOURCE_BUNDLE_ABANDON_PATH,
            post(super::routes_source_bundle::abandon_source_bundle).layer(DefaultBodyLimit::max(
                SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES,
            )),
        )
        .route(
            CLAIM_PATH,
            post(claim).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            LEASE_RENEW_PATH,
            post(renew_lease).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            STATUS_PATH,
            post(status).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            CANCEL_PATH,
            post(cancel).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            SETTLED_PATH,
            post(settled).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            ARTIFACT_PATH,
            post(fetch_artifact).layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
        .route(
            super::routes_cleanup::CLEANUP_OBSERVATION_PATH,
            post(super::routes_cleanup::observe_cleanup)
                .layer(DefaultBodyLimit::max(MAX_REMOTE_LIFECYCLE_JSON_BYTES)),
        )
}

pub(crate) fn execution_operation(method: &Method, path: &str) -> Option<&'static str> {
    match (method, path) {
        (&Method::GET, ADVERTISE_PATH) => Some("advertise"),
        (&Method::POST, HEARTBEAT_PATH) => Some("heartbeat"),
        (&Method::POST, OFFER_PATH) => Some("offer"),
        (&Method::POST, SOURCE_BUNDLE_PATH) => Some("upload_source_bundle"),
        (&Method::POST, SOURCE_BUNDLE_RECEIPT_PATH) => Some("verify_source_bundle_receipt"),
        (&Method::POST, SOURCE_BUNDLE_ABANDON_PATH) => Some("abandon_source_bundle"),
        (&Method::POST, CLAIM_PATH) => Some("claim"),
        (&Method::POST, LEASE_RENEW_PATH) => Some("renew_lease"),
        (&Method::POST, STATUS_PATH) => Some("status"),
        (&Method::POST, CANCEL_PATH) => Some("cancel"),
        (&Method::POST, SETTLED_PATH) => Some("settled"),
        (&Method::POST, ARTIFACT_PATH) => Some("fetch_artifact"),
        (&Method::POST, super::routes_cleanup::CLEANUP_OBSERVATION_PATH) => Some("observe_cleanup"),
        _ => None,
    }
}

async fn upload_source_bundle(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteSourceBundleUploadRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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

async fn advertise(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    map_route_result(
        async {
            let db = require_async_db(&state, "advertise remote execution host")?;
            let host = local_host(db).await?;
            let client =
                require_execution_remote_client(&headers, &state, "advertise").map_err(|_| {
                    crate::errors::CliErrorKind::session_permission_denied(
                        "remote executor authorization denied",
                    )
                })?;
            verify_route_identity(&host, &state.daemon_epoch, &client.client_id, None)?;
            let active = active_assignments(db, &host).await?;
            host_wire_advertisement(&host, &state.daemon_epoch, active, utc_now())
                .map_err(wire_error)
        }
        .await,
    )
}

async fn heartbeat(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteHeartbeatRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
            let db = require_async_db(&state, "heartbeat remote execution host")?;
            let host = local_host(db).await?;
            let client =
                require_execution_remote_client(&headers, &state, "heartbeat").map_err(|_| {
                    crate::errors::CliErrorKind::session_permission_denied(
                        "remote executor authorization denied",
                    )
                })?;
            verify_route_identity(
                &host,
                &state.daemon_epoch,
                &client.client_id,
                Some((&request.host_id, &request.host_instance_id)),
            )?;
            let now = Utc::now();
            verify_heartbeat_time(&request.sent_at, now)?;
            if request.active_assignments != active_assignments(db, &host).await? {
                return Err(concurrent("remote heartbeat capacity evidence is stale"));
            }
            Ok(RemoteHeartbeatResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                host_id: host.host_id,
                host_instance_id: state.daemon_epoch,
                accepted_at: canonical_time(now),
                next_heartbeat_deadline: canonical_time(
                    now + Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS),
                ),
            })
        }
        .await,
    )
}

async fn offer(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteOfferRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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

async fn claim(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteClaimRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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

async fn renew_lease(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteLeaseRenewRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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

async fn status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteStatusRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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

async fn cancel(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteCancelRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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
            .map_err(wire_error)
        }
        .await,
    )
}

async fn settled(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteSettledRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
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

async fn fetch_artifact(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteArtifactFetchRequest>,
) -> Response {
    let result = async {
        request.validate().map_err(wire_error)?;
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
        Err(error) => map_route_error(error),
    }
}
