use axum::Json;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse as _, Response};
use chrono::{DateTime, Duration, SecondsFormat, Utc};

use super::wire::{
    RemoteAttemptBinding, RemoteLease, RemoteOfferDisposition, RemoteOfferRequest,
    RemoteOfferResponse, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome,
    TaskBoardRemoteOfferReceipt, TaskBoardRemoteOfferReceiptDisposition,
};
use crate::daemon::http::{DaemonHttpState, require_async_db, require_execution_remote_client};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS, TaskBoardLocalExecutionHostConfig,
    TaskBoardOrchestratorSettings, TaskBoardRemoteAssignmentState,
    validate_local_execution_host_config,
};

pub(super) async fn assignment_route<'a>(
    headers: &HeaderMap,
    state: &'a DaemonHttpState,
    operation: &'static str,
    binding: &RemoteAttemptBinding,
) -> Result<(&'a AsyncDaemonDb, String), CliError> {
    let db = require_async_db(state, "handle remote executor operation")?;
    let client = require_execution_remote_client(headers, state, operation).map_err(|_| {
        CliErrorKind::session_permission_denied("remote executor authorization denied")
    })?;
    let stale_claim = if operation == "claim" && binding.host_instance_id != state.daemon_epoch {
        db.task_board_remote_assignment(&binding.assignment_id)
            .await?
            .is_none_or(|record| record.claim_receipt.is_none())
    } else {
        false
    };
    if client.client_id != binding.host_id || stale_claim {
        return Err(CliErrorKind::session_permission_denied(
            "remote executor credential or target identity mismatched",
        )
        .into());
    }
    Ok((db, client.client_id))
}

pub(super) async fn local_host(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardLocalExecutionHostConfig, CliError> {
    let TaskBoardOrchestratorSettings {
        local_execution_host: host,
        ..
    } = db.task_board_orchestrator_settings().await?;
    validate_local_execution_host_config(&host)?;
    if !host.enabled {
        return Err(CliErrorKind::workflow_parse("local remote executor is disabled").into());
    }
    Ok(host)
}

pub(super) async fn active_assignments(
    db: &AsyncDaemonDb,
    host: &TaskBoardLocalExecutionHostConfig,
) -> Result<u32, CliError> {
    let active = db
        .task_board_remote_executor_active_assignment_count(&host.host_id)
        .await?;
    if active > host.capacity {
        return Err(concurrent("remote executor capacity is oversubscribed"));
    }
    Ok(active)
}

pub(super) fn verify_route_identity(
    host: &TaskBoardLocalExecutionHostConfig,
    host_instance_id: &str,
    principal: &str,
    requested: Option<(&str, &str)>,
) -> Result<(), CliError> {
    let requested_matches = requested.is_none_or(|(host_id, instance_id)| {
        host_id == host.host_id && instance_id == host_instance_id
    });
    if principal == host.host_id && requested_matches {
        Ok(())
    } else {
        Err(CliErrorKind::session_permission_denied(
            "remote executor credential or target identity mismatched",
        )
        .into())
    }
}

pub(super) fn offer_response(
    outcome: TaskBoardRemoteOfferOutcome,
    request: &RemoteOfferRequest,
) -> Result<RemoteOfferResponse, CliError> {
    let (disposition, lease, rejection_code) = match outcome {
        TaskBoardRemoteOfferOutcome::Created(record) => accepted_offer(&record)?,
        TaskBoardRemoteOfferOutcome::AcceptedReplay(receipt) => {
            accepted_offer_receipt(&receipt, request)?
        }
        TaskBoardRemoteOfferOutcome::Rejected(receipt) => {
            rejected_offer_receipt(&receipt, request)?
        }
        TaskBoardRemoteOfferOutcome::Replayed(_) => {
            return Err(concurrent(
                "remote executor offer replay lacks an immutable receipt",
            ));
        }
        TaskBoardRemoteOfferOutcome::Unavailable => {
            return Err(concurrent(
                "remote offer rejection lacks durable replay evidence",
            ));
        }
        TaskBoardRemoteOfferOutcome::Stale => {
            return Err(concurrent("remote offer is stale"));
        }
    };
    Ok(RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition,
        lease,
        rejection_code,
    })
}

fn accepted_offer_receipt(
    receipt: &TaskBoardRemoteOfferReceipt,
    request: &RemoteOfferRequest,
) -> Result<(RemoteOfferDisposition, Option<RemoteLease>, Option<String>), CliError> {
    let exact = receipt.request == *request
        && receipt.authenticated_principal == request.binding.host_id
        && receipt.disposition == TaskBoardRemoteOfferReceiptDisposition::Accepted
        && receipt.rejection_code.is_none();
    if !exact {
        return Err(concurrent("accepted remote offer receipt is malformed"));
    }
    Ok((
        RemoteOfferDisposition::Accepted,
        Some(RemoteLease {
            lease_id: required(
                receipt.initial_lease_id.clone(),
                "accepted remote offer receipt lease id",
            )?,
            expires_at: required(
                receipt.initial_lease_expires_at.clone(),
                "accepted remote offer receipt lease expiry",
            )?,
        }),
        None,
    ))
}

fn rejected_offer_receipt(
    receipt: &TaskBoardRemoteOfferReceipt,
    request: &RemoteOfferRequest,
) -> Result<(RemoteOfferDisposition, Option<RemoteLease>, Option<String>), CliError> {
    let exact = receipt.request == *request
        && receipt.authenticated_principal == request.binding.host_id
        && receipt.disposition == TaskBoardRemoteOfferReceiptDisposition::Rejected
        && receipt.initial_lease_id.is_none()
        && receipt.initial_lease_expires_at.is_none()
        && receipt.rejection_code.as_deref() == Some("executor_unavailable");
    if !exact {
        return Err(concurrent("rejected remote offer receipt is malformed"));
    }
    Ok((
        RemoteOfferDisposition::Rejected,
        None,
        receipt.rejection_code.clone(),
    ))
}

fn accepted_offer(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<(RemoteOfferDisposition, Option<RemoteLease>, Option<String>), CliError> {
    let active = matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Offered
            | TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    );
    if active {
        Ok((
            RemoteOfferDisposition::Accepted,
            Some(record_lease(record)?),
            None,
        ))
    } else {
        Err(concurrent("accepted remote offer is no longer active"))
    }
}

pub(super) fn record_lease(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteLease, CliError> {
    Ok(RemoteLease {
        lease_id: required(record.lease_id.clone(), "remote lease id")?,
        expires_at: required(record.lease_expires_at.clone(), "remote lease expiry")?,
    })
}

pub(super) async fn load_assignment(
    db: &AsyncDaemonDb,
    assignment_id: &str,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    db.task_board_remote_assignment(assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote assignment does not exist"))
}

pub(super) fn verify_heartbeat_time(value: &str, now: DateTime<Utc>) -> Result<(), CliError> {
    let sent = DateTime::parse_from_rfc3339(value)
        .map(DateTime::<Utc>::from)
        .map_err(|_| CliErrorKind::workflow_parse("remote heartbeat time is invalid"))?;
    if sent <= now && sent >= now - Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS) {
        Ok(())
    } else {
        Err(concurrent("remote heartbeat is outside its accepted TTL"))
    }
}

pub(super) fn canonical_time(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

pub(super) fn required(value: Option<String>, field: &'static str) -> Result<String, CliError> {
    value.ok_or_else(|| concurrent(field))
}

pub(super) fn wire_error(error: &RemoteWireError) -> CliError {
    CliErrorKind::workflow_parse(error.to_string()).into()
}

pub(super) fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}

pub(super) fn map_route_result<T: serde::Serialize>(result: Result<T, CliError>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) => map_route_error(&error),
    }
}

pub(super) fn map_route_error(error: &CliError) -> Response {
    let status = match error.code() {
        "WORKFLOW_CONCURRENT" => StatusCode::CONFLICT,
        "WORKFLOW_IO" => StatusCode::SERVICE_UNAVAILABLE,
        "SESSION_SCOPE_DENIED" | "KSRCLI091" => StatusCode::FORBIDDEN,
        _ => StatusCode::BAD_REQUEST,
    };
    route_error(status, error.code(), &error.message())
}

pub(super) fn route_error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({
            "error": {
                "code": code,
                "message": message,
            }
        })),
    )
        .into_response()
}
