use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;

use super::routes_support::{assignment_route, map_route_result, wire_error};
use super::wire::{RemoteSourceBundleAbandonRequest, RemoteSourceBundleUploadRequest};
use crate::daemon::db::utc_now;
use crate::daemon::http::DaemonHttpState;

pub(super) async fn verify_source_bundle_receipt(
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
                "verify_source_bundle_receipt",
                &request.offer.binding,
            )
            .await?;
            db.verify_task_board_remote_source_bundle_receipt(
                &request,
                &principal,
                &state.daemon_epoch,
                &utc_now(),
            )
            .await
        }
        .await,
    )
}

pub(super) async fn abandon_source_bundle(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteSourceBundleAbandonRequest>,
) -> Response {
    map_route_result(
        async {
            request.validate().map_err(wire_error)?;
            let (db, principal) = assignment_route(
                &headers,
                &state,
                "abandon_source_bundle",
                &request.offer.binding,
            )
            .await?;
            Ok(db
                .abandon_task_board_remote_source_bundle(
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
