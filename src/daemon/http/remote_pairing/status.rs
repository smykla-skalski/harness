use std::time::Instant;

use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::daemon::db::DaemonDb;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision,
};
use crate::daemon::remote_pairing::RemotePairingStatus;
use crate::workspace::utc_now;

use super::super::response::{extract_request_id, timed_json, timed_response};
use super::super::{DaemonConnectInfo, DaemonHttpState};

const ROUTE_REMOTE_PAIR_STATUS: &str = "remote.pair.status";
const UNAVAILABLE_DETAIL: &str = "remote pairing status unavailable";

pub(super) fn remote_pairing_status_routes() -> Router<DaemonHttpState> {
    Router::new().route(
        http_paths::REMOTE_PAIR_STATUS,
        post(post_remote_pair_status),
    )
}

#[derive(Debug, Deserialize)]
struct RemotePairStatusHttpRequest {
    pairing_id: String,
}

#[derive(Debug, Serialize)]
struct RemotePairStatusHttpResponse {
    status: &'static str,
}

async fn post_remote_pair_status(
    ConnectInfo(connect_info): ConnectInfo<DaemonConnectInfo>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemotePairStatusHttpRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    let remote_addr = connect_info.remote_addr().ip().to_string();
    match load_remote_pairing_status(
        &state,
        request.pairing_id.as_str(),
        request_id.as_str(),
        remote_addr.as_str(),
    ) {
        Ok(status) => timed_json(
            "POST",
            http_paths::REMOTE_PAIR_STATUS,
            request_id.as_str(),
            start,
            Ok(RemotePairStatusHttpResponse {
                status: status.as_str(),
            }),
        ),
        Err(error) => timed_response(
            "POST",
            http_paths::REMOTE_PAIR_STATUS,
            request_id.as_str(),
            start,
            error.into_response(),
        ),
    }
}

fn load_remote_pairing_status(
    state: &DaemonHttpState,
    pairing_id: &str,
    request_id: &str,
    remote_addr: &str,
) -> Result<RemotePairingStatus, RemotePairStatusHttpError> {
    ensure_remote_pairing_configured(state)?;
    let now = utc_now();
    let db = state
        .db
        .get()
        .ok_or(RemotePairStatusHttpError::StoreUnavailable)?
        .lock()
        .map_err(|_| RemotePairStatusHttpError::StoreUnavailable)?;
    let status = db
        .load_remote_pairing_status(pairing_id, now.as_str())
        .map_err(|_| RemotePairStatusHttpError::StoreUnavailable)?;
    record_status_audit(&db, status, request_id, remote_addr, now.as_str())?;
    Ok(status)
}

fn ensure_remote_pairing_configured(
    state: &DaemonHttpState,
) -> Result<(), RemotePairStatusHttpError> {
    if state
        .remote_domain
        .as_deref()
        .is_some_and(|domain| !domain.trim().is_empty())
    {
        Ok(())
    } else {
        Err(RemotePairStatusHttpError::MissingRemoteDomain)
    }
}

fn record_status_audit(
    db: &DaemonDb,
    status: RemotePairingStatus,
    request_id: &str,
    remote_addr: &str,
    now: &str,
) -> Result<(), RemotePairStatusHttpError> {
    let unavailable = status == RemotePairingStatus::Unavailable;
    let event = RemoteAuditEvent::new(
        format!("remote-pair-status-{}", Uuid::new_v4()),
        now,
        Some(request_id),
        None,
        ROUTE_REMOTE_PAIR_STATUS,
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Allowed,
        if unavailable {
            RemoteAuditOutcome::Failure
        } else {
            RemoteAuditOutcome::Success
        },
        Some(remote_addr),
        unavailable.then_some(UNAVAILABLE_DETAIL),
    );
    db.record_remote_audit_event(&event)
        .map_err(|_| RemotePairStatusHttpError::StoreUnavailable)
}

#[derive(Debug)]
enum RemotePairStatusHttpError {
    MissingRemoteDomain,
    StoreUnavailable,
}

impl IntoResponse for RemotePairStatusHttpError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::MissingRemoteDomain => (
                StatusCode::SERVICE_UNAVAILABLE,
                "REMOTE_PAIRING_CONFIG",
                "remote pairing is not configured",
            ),
            Self::StoreUnavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "REMOTE_PAIRING_STORE",
                "remote pairing store is unavailable",
            ),
        };
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
}
