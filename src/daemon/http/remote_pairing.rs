use std::net::SocketAddr;
use std::time::Instant;

use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::daemon::db::RemotePairingClaimCodeError;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision,
};
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingClaimedClient, RemotePairingCodeHash,
    RemotePairingError,
};
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::ReviewsQueryRequest;
use crate::workspace::utc_now;

use super::response::{extract_request_id, timed_json, timed_response};
use super::{DaemonConnectInfo, DaemonHttpState};

pub(super) fn remote_pairing_routes() -> Router<DaemonHttpState> {
    Router::new().route(http_paths::REMOTE_PAIR_CLAIM, post(post_remote_pair_claim))
}

#[derive(Debug, Deserialize)]
pub(crate) struct RemotePairClaimHttpRequest {
    code: String,
    domain: String,
    client_id: String,
    display_name: String,
    platform: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct RemotePairClaimHttpResponse {
    client_id: String,
    display_name: String,
    platform: String,
    role: String,
    scopes: Vec<String>,
    token: String,
    token_hint: String,
    paired_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    reviews_query: Option<ReviewsQueryRequest>,
}

async fn post_remote_pair_claim(
    ConnectInfo(connect_info): ConnectInfo<DaemonConnectInfo>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemotePairClaimHttpRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    match claim_remote_pairing(
        connect_info.remote_addr(),
        &state,
        &request,
        request_id.as_str(),
    ) {
        Ok(response) => timed_json(
            "POST",
            http_paths::REMOTE_PAIR_CLAIM,
            request_id.as_str(),
            start,
            Ok(response),
        ),
        Err(error) => timed_response(
            "POST",
            http_paths::REMOTE_PAIR_CLAIM,
            request_id.as_str(),
            start,
            error.into_response(),
        ),
    }
}

fn claim_remote_pairing(
    peer_addr: SocketAddr,
    state: &DaemonHttpState,
    request: &RemotePairClaimHttpRequest,
    request_id: &str,
) -> Result<RemotePairClaimHttpResponse, RemotePairClaimHttpError> {
    let remote_addr = remote_addr(peer_addr);
    claim_remote_pairing_for_addr(state, request, request_id, remote_addr.as_str())
}

fn claim_remote_pairing_for_addr(
    state: &DaemonHttpState,
    request: &RemotePairClaimHttpRequest,
    request_id: &str,
    remote_addr: &str,
) -> Result<RemotePairClaimHttpResponse, RemotePairClaimHttpError> {
    let claim = authorize_pairing_claim(state, request, remote_addr)?;
    let claimed = claim_pairing_client(state, request.code.as_str(), &claim)?;
    log_remote_pairing_claimed(request_id, claimed.client.client_id.as_str());
    Ok(remote_pair_claim_response(claimed))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_remote_pairing_claimed(request_id: &str, client_id: &str) {
    tracing::debug!(request_id, client_id, "remote pairing claimed");
}

fn authorize_pairing_claim(
    state: &DaemonHttpState,
    request: &RemotePairClaimHttpRequest,
    remote_addr: &str,
) -> Result<RemotePairingClaimRequest, RemotePairClaimHttpError> {
    check_claim_rate_limit(state, request.code.as_str(), remote_addr)?;
    let expected_domain = expected_remote_domain(state)?;
    build_pairing_claim(expected_domain, request, remote_addr)
}

fn expected_remote_domain(state: &DaemonHttpState) -> Result<&str, RemotePairClaimHttpError> {
    state
        .remote_domain
        .as_deref()
        .map(str::trim)
        .filter(|domain| !domain.is_empty())
        .ok_or(RemotePairClaimHttpError::MissingRemoteDomain)
}

fn build_pairing_claim(
    expected_domain: &str,
    request: &RemotePairClaimHttpRequest,
    remote_addr: &str,
) -> Result<RemotePairingClaimRequest, RemotePairClaimHttpError> {
    let audit_event_id = format!("remote-pair-claim-{}", Uuid::new_v4());
    RemotePairingClaimRequest::new(
        expected_domain,
        request.domain.as_str(),
        request.client_id.as_str(),
        request.display_name.as_str(),
        request.platform.as_str(),
        Some(remote_addr),
        audit_event_id,
    )
    .map_err(RemotePairClaimHttpError::Pairing)
}

fn claim_pairing_client(
    state: &DaemonHttpState,
    code: &str,
    claim: &RemotePairingClaimRequest,
) -> Result<RemotePairingClaimedClient, RemotePairClaimHttpError> {
    let now = utc_now();
    let db = state
        .db
        .get()
        .ok_or(RemotePairClaimHttpError::StoreUnavailable)?
        .lock()
        .map_err(|_| RemotePairClaimHttpError::StoreUnavailable)?;
    let claimed = db
        .claim_remote_pairing_code(code, claim, now.as_str())
        .map_err(RemotePairClaimHttpError::from_claim_error)?;
    Ok(claimed)
}

fn remote_pair_claim_response(claimed: RemotePairingClaimedClient) -> RemotePairClaimHttpResponse {
    RemotePairClaimHttpResponse {
        client_id: claimed.client.client_id,
        display_name: claimed.client.display_name,
        platform: claimed.client.platform,
        role: claimed.client.role.as_str().to_string(),
        scopes: claimed
            .client
            .scopes
            .iter()
            .map(|scope| scope.as_str().to_string())
            .collect(),
        token: claimed.bearer_token.expose().to_string(),
        token_hint: claimed.client.token_hint,
        paired_at: claimed.client.created_at,
        reviews_query: claimed.reviews_query,
    }
}

fn check_claim_rate_limit(
    state: &DaemonHttpState,
    code: &str,
    remote_addr: &str,
) -> Result<(), RemotePairClaimHttpError> {
    let code_fingerprint = RemotePairingCodeHash::from_code(code).map_or_else(
        |_| "<invalid-code>".to_string(),
        |hash| hash.as_storage_value().to_string(),
    );
    let mut limiter = state
        .remote_pairing_limiter
        .lock()
        .map_err(|_| RemotePairClaimHttpError::StoreUnavailable)?;
    limiter
        .record_attempt(remote_addr, code_fingerprint.as_str())
        .map_err(|error| match error {
            RemotePairingError::RateLimited => {
                let _ = record_rate_limit_audit(state, remote_addr);
                RemotePairClaimHttpError::RateLimited
            }
            other => RemotePairClaimHttpError::Pairing(other),
        })
}

fn record_rate_limit_audit(state: &DaemonHttpState, remote_addr: &str) -> Result<(), CliError> {
    let Some(db) = state.db.get() else {
        return Ok(());
    };
    let db = db
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("remote pairing db lock: {error}")))?;
    let event_id = format!("remote-pair-rate-limit-{}", Uuid::new_v4());
    db.record_remote_audit_event(&RemoteAuditEvent::new(
        event_id.as_str(),
        utc_now().as_str(),
        None,
        None,
        "remote.pair.rate_limit",
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Denied,
        RemoteAuditOutcome::Failure,
        Some(remote_addr),
        Some("remote pairing attempts are rate limited"),
    ))
}

fn remote_addr(peer_addr: SocketAddr) -> String {
    peer_addr.ip().to_string()
}

#[derive(Debug)]
enum RemotePairClaimHttpError {
    MissingRemoteDomain,
    StoreUnavailable,
    RateLimited,
    Pairing(RemotePairingError),
}

impl RemotePairClaimHttpError {
    fn from_claim_error(error: RemotePairingClaimCodeError) -> Self {
        match error {
            RemotePairingClaimCodeError::Pairing(error) => Self::Pairing(error),
            RemotePairingClaimCodeError::Store(_) => Self::StoreUnavailable,
        }
    }
}

impl IntoResponse for RemotePairClaimHttpError {
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
            Self::RateLimited => (
                StatusCode::TOO_MANY_REQUESTS,
                "REMOTE_PAIRING_RATE_LIMIT",
                "remote pairing attempts are rate limited",
            ),
            Self::Pairing(error) => {
                let status = pairing_error_status(&error);
                let message = pairing_error_message(&error);
                return (
                    status,
                    Json(serde_json::json!({
                        "error": {
                            "code": "REMOTE_PAIRING",
                            "message": message,
                        }
                    })),
                )
                    .into_response();
            }
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

fn pairing_error_status(error: &RemotePairingError) -> StatusCode {
    match error {
        RemotePairingError::AlreadyClaimed => StatusCode::CONFLICT,
        RemotePairingError::Expired => StatusCode::GONE,
        RemotePairingError::WrongDomain { .. } => StatusCode::FORBIDDEN,
        RemotePairingError::RateLimited => StatusCode::TOO_MANY_REQUESTS,
        RemotePairingError::EmptyPairingId
        | RemotePairingError::EmptyCode
        | RemotePairingError::EmptyClientId
        | RemotePairingError::EmptyDomain
        | RemotePairingError::EmptyDisplayName
        | RemotePairingError::EmptyPlatform
        | RemotePairingError::EmptyAuditEventId
        | RemotePairingError::InvalidStoredCodeHash
        | RemotePairingError::InvalidReviewsQuery(_)
        | RemotePairingError::UnknownCode
        | RemotePairingError::Identity(_) => StatusCode::BAD_REQUEST,
    }
}

fn pairing_error_message(error: &RemotePairingError) -> &'static str {
    match error {
        RemotePairingError::AlreadyClaimed => "remote pairing code already claimed",
        RemotePairingError::Expired => "remote pairing code expired",
        RemotePairingError::WrongDomain { .. } => "remote pairing domain is not allowed",
        RemotePairingError::RateLimited => "remote pairing attempts are rate limited",
        RemotePairingError::EmptyPairingId => "remote pairing id is required",
        RemotePairingError::EmptyCode => "remote pairing code is required",
        RemotePairingError::EmptyClientId => "remote pairing client id is required",
        RemotePairingError::EmptyDomain => "remote pairing domain is required",
        RemotePairingError::EmptyDisplayName => "remote pairing display name is required",
        RemotePairingError::EmptyPlatform => "remote pairing platform is required",
        RemotePairingError::EmptyAuditEventId => "remote pairing audit event id is required",
        RemotePairingError::InvalidStoredCodeHash => "remote pairing code is invalid",
        RemotePairingError::InvalidReviewsQuery(_) => "remote pairing reviews query is invalid",
        RemotePairingError::UnknownCode => "remote pairing code is unknown",
        RemotePairingError::Identity(_) => "remote pairing client identity is invalid",
    }
}
