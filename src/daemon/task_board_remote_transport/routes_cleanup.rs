//! Authenticated read of exact executor cleanup completion evidence.

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;

use super::routes_support::{
    assignment_route, concurrent, load_assignment, map_route_error, map_route_result, route_error,
    wire_error,
};
use super::wire::RemoteAssignmentWireState;
use super::wire_cleanup::{RemoteCleanupObservationRequest, RemoteCleanupObservationResponse};
use crate::daemon::db::TaskBoardRemoteAssignmentRecord;
use crate::daemon::http::DaemonHttpState;
#[cfg(feature = "openapi")]
use crate::daemon::http::openapi::DaemonErrorBody;

pub(crate) const CLEANUP_OBSERVATION_PATH: &str = "/v1/task-board-execution/cleanup/observe";

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board-execution/cleanup/observe",
    tag = "task-board-execution",
    description = "Read exact executor cleanup completion evidence for a settled assignment. Responds 503 with the REMOTE_CLEANUP_PENDING code when cleanup has not yet completed.",
    request_body = RemoteCleanupObservationRequest,
    responses(
        (status = 200, description = "Cleanup completion observation", body = RemoteCleanupObservationResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn observe_cleanup(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemoteCleanupObservationRequest>,
) -> Response {
    let result = async {
        request.validate().map_err(|error| wire_error(&error))?;
        let (db, principal) =
            assignment_route(&headers, &state, "observe_cleanup", &request.binding).await?;
        let record = load_assignment(db, &request.binding.assignment_id).await?;
        cleanup_response(&record, &request, &principal)
    }
    .await;
    match result {
        Ok(Some(response)) => map_route_result(Ok(response)),
        Ok(None) => route_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "REMOTE_CLEANUP_PENDING",
            "remote executor cleanup has not completed",
        ),
        Err(error) => map_route_error(&error),
    }
}

fn cleanup_response(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
    principal: &str,
) -> Result<Option<RemoteCleanupObservationResponse>, crate::errors::CliError> {
    let offer = record.require_offer()?;
    let exact = offer.binding == request.binding
        && offer.request_sha256 == request.offer_request_sha256
        && record.fencing_epoch == request.binding.fencing_epoch
        && record.lease_id.as_deref() == Some(request.lease_id.as_str())
        && record.authenticated_principal.as_deref() == Some(principal)
        && matches!(
            record.wire_state(),
            RemoteAssignmentWireState::Completed
                | RemoteAssignmentWireState::Failed
                | RemoteAssignmentWireState::Cancelled
                | RemoteAssignmentWireState::Superseded
                | RemoteAssignmentWireState::Unknown
        );
    if !exact {
        return Err(concurrent(
            "remote cleanup observation mismatched its assignment generation",
        ));
    }
    let Some(cleanup_completed_at) = record.cleanup_completed_at.clone() else {
        if record.cleanup_settlement_request_sha256.is_some() {
            return Err(concurrent(
                "remote cleanup observation marker is incomplete",
            ));
        }
        return Ok(None);
    };
    if record.cleanup_settlement_request_sha256.as_deref()
        != Some(request.settlement_request_sha256.as_str())
    {
        return Err(concurrent(
            "remote cleanup observation mismatched its settlement authority",
        ));
    }
    RemoteCleanupObservationResponse::for_completed(request, cleanup_completed_at)
        .map(Some)
        .map_err(|error| wire_error(&error))
}
