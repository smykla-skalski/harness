//! Listing pairings and revoking one that is not the caller's own.
//!
//! Both routes need the `pair_manage` scope. What that scope alone buys is the
//! caller's own entries: the links it minted. Seeing or touching everyone
//! else's additionally needs `admin`, so a broker credential that leaks can
//! only reach the links that broker issued.
//!
//! A pairing minted before the owner was recorded has none stored, so it reads
//! as the host's and only an `admin` caller sees it. That is the safe direction
//! and the only honest one: the daemon never wrote down which broker minted
//! those, and attributing them to whichever broker asks would hand one broker
//! another's links.

use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;
use uuid::Uuid;

use crate::daemon::db::{RemotePairingOwner, RemotePairingRevokeOutcome as Outcome};
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteStoredClient,
};
use crate::daemon::remote_pairing::RemotePairingInventoryEntry;
use crate::workspace::utc_now;
use harness_kernel::errors::CliError;

use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_response};
use super::super::{DaemonHttpState, authenticated_remote_client, require_async_db};

pub(in crate::daemon::http) fn remote_pairing_manage_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_remote_pairings))
        .routes(routes!(post_remote_pairing_revoke))
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RemotePairingListResponse {
    pairings: Vec<RemotePairingInventoryEntry>,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RemotePairingRevokeResponse {
    pairing_id: String,
    /// What the revoke did: `device_revoked`, `link_withdrawn`, or
    /// `already_revoked`.
    outcome: String,
    revoked_at: String,
}

/// Whether the caller may see beyond what it minted.
///
/// A caller holding `admin` alongside `pair_manage` is an operator of the
/// daemon itself, so the inventory is theirs to read. Anyone else sees the
/// links they are responsible for, which for the companion panel is everything
/// it minted and nothing an operator created on the host.
fn sees_every_pairing(client: Option<&RemoteStoredClient>) -> bool {
    // Local mode has no client and is already the host operator.
    client.is_none_or(|client| client.scopes.contains(&RemoteAccessScope::Admin))
}

#[utoipa::path(
    get,
    path = "/v1/remote/pairings",
    tag = "pairing",
    description = "List pairing links and the devices they became. Requires the pair_manage scope, which shows the caller the links it minted; a caller that also holds admin sees every pairing. Beyond the shared middleware causes, this route answers 503 when the pairing store is unavailable",
    responses(
        (status = 200, description = "Pairings the caller may see", body = RemotePairingListResponse),
        (status = 503, description = "Pairing store unavailable", body = DaemonErrorBody),
    ),
)]
async fn get_remote_pairings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    let response = match list_pairings(&headers, &state) {
        Ok(body) => Json(body).into_response(),
        Err(error) => error.into_response(),
    };
    timed_response(
        "GET",
        http_paths::REMOTE_PAIRINGS,
        &request_id,
        start,
        response,
    )
}

fn list_pairings(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<RemotePairingListResponse, RemotePairingManageError> {
    let client = authenticated_remote_client(headers, state)
        .map_err(RemotePairingManageError::Authentication)?;
    let db = state
        .db
        .get()
        .ok_or(RemotePairingManageError::StoreUnavailable)?
        .lock()
        .map_err(|_| RemotePairingManageError::StoreUnavailable)?;
    let now = utc_now();
    // The narrowing is the query's, not a filter applied after reading every
    // link the daemon has ever issued.
    let owner = if sees_every_pairing(client.as_ref()) {
        None
    } else {
        Some(client.map(|client| client.client_id).unwrap_or_default())
    };
    let pairings = db
        .list_remote_pairing_inventory(now.as_str(), owner.as_deref())
        .map_err(RemotePairingManageError::Store)?;
    drop(db);

    Ok(RemotePairingListResponse { pairings })
}

#[utoipa::path(
    post,
    path = "/v1/remote/pairings/{pairing_id}/revoke",
    tag = "pairing",
    params(("pairing_id" = String, Path, description = "Pairing to revoke")),
    description = "Revoke a pairing, cutting off somebody else's device rather than the caller's own credential. A claimed link cuts off the device it became; an unclaimed one can no longer be claimed. Requires the pair_manage scope, and the caller must have minted the pairing unless it also holds admin. Beyond the shared middleware causes, this route answers 503 when the pairing store is unavailable",
    responses(
        (status = 200, description = "Pairing revoked", body = RemotePairingRevokeResponse),
        (status = 403, description = "Pairing belongs to another caller", body = DaemonErrorBody),
        (status = 404, description = "No such pairing", body = DaemonErrorBody),
    ),
)]
async fn post_remote_pairing_revoke(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Path(pairing_id): Path<String>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    let response = match revoke_pairing(&headers, &state, &pairing_id, &request_id).await {
        Ok(body) => Json(body).into_response(),
        Err(error) => error.into_response(),
    };
    timed_response(
        "POST",
        http_paths::REMOTE_PAIRING_REVOKE,
        &request_id,
        start,
        response,
    )
}

async fn revoke_pairing(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    pairing_id: &str,
    request_id: &str,
) -> Result<RemotePairingRevokeResponse, RemotePairingManageError> {
    let client = authenticated_remote_client(headers, state)
        .map_err(RemotePairingManageError::Authentication)?;
    require_may_revoke(state, client.as_ref(), pairing_id)?;

    let revoked_at = utc_now();
    let audit = revoke_audit(client.as_ref(), pairing_id, request_id, revoked_at.as_str())
        .map_err(RemotePairingManageError::Store)?;
    let db = require_async_db(state, "revoke remote pairing")
        .map_err(RemotePairingManageError::Store)?;
    let revoked = db
        .revoke_remote_pairing_with_audit(pairing_id, revoked_at.as_str(), &audit)
        .await
        .map_err(RemotePairingManageError::Store)?;

    let label = match revoked.outcome {
        Outcome::DeviceRevoked => "device_revoked",
        Outcome::LinkWithdrawn => "link_withdrawn",
        Outcome::AlreadyRevoked => "already_revoked",
        Outcome::NotFound => return Err(RemotePairingManageError::NotFound),
    };
    Ok(RemotePairingRevokeResponse {
        pairing_id: pairing_id.to_owned(),
        outcome: label.to_owned(),
        // What the store reports, which for an already-revoked pairing is when
        // it was really cut off rather than when this request arrived.
        revoked_at: revoked.revoked_at,
    })
}

/// Refuse a pairing the caller did not mint.
///
/// The lookup is deliberately the same list the caller is allowed to read, so
/// a pairing it may not see answers the same way whether or not it exists. A
/// distinct "no such pairing" for other people's ids would let a broker probe
/// for them.
fn require_may_revoke(
    state: &DaemonHttpState,
    client: Option<&RemoteStoredClient>,
    pairing_id: &str,
) -> Result<(), RemotePairingManageError> {
    if sees_every_pairing(client) {
        return Ok(());
    }
    let client_id = client.map_or("", |client| client.client_id.as_str());
    let db = state
        .db
        .get()
        .ok_or(RemotePairingManageError::StoreUnavailable)?
        .lock()
        .map_err(|_| RemotePairingManageError::StoreUnavailable)?;
    // Asked about one pairing rather than by scanning the inventory, which
    // would have read and decoded every row the daemon has ever issued to
    // answer a question about one of them.
    let owner = db
        .remote_pairing_minted_by(pairing_id)
        .map_err(RemotePairingManageError::Store)?;
    drop(db);
    let owns = matches!(owner, RemotePairingOwner::Client(ref owner) if owner == client_id);
    if owns {
        Ok(())
    } else {
        Err(RemotePairingManageError::NotYours)
    }
}

fn revoke_audit(
    client: Option<&RemoteStoredClient>,
    pairing_id: &str,
    request_id: &str,
    recorded_at: &str,
) -> Result<RemoteAuditEvent, CliError> {
    let event_id = format!("remote-pairing-revoke-{}", Uuid::new_v4());
    let metadata = serde_json::to_string(&serde_json::json!({ "pairing_id": pairing_id }))
        .map_err(|error| {
            crate::daemon::db::db_error(format!("encode remote pairing revoke metadata: {error}"))
        })?;
    Ok(RemoteAuditEvent::new(
        event_id.as_str(),
        recorded_at,
        Some(request_id),
        client.map(|client| client.client_id.as_str()),
        "remote.pairing.revoke",
        RemoteAccessScope::PairManage,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        None,
        None,
    )
    .with_metadata_json(metadata))
}

enum RemotePairingManageError {
    Authentication(Box<Response>),
    StoreUnavailable,
    NotYours,
    NotFound,
    Store(CliError),
}

impl IntoResponse for RemotePairingManageError {
    fn into_response(self) -> Response {
        match self {
            Self::Authentication(response) => *response,
            Self::StoreUnavailable => manage_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "pairing_store_unavailable",
                "pairing store is unavailable",
            ),
            Self::NotYours => manage_error(
                StatusCode::FORBIDDEN,
                "pairing_not_yours",
                "this pairing was minted by another client",
            ),
            Self::NotFound => manage_error(
                StatusCode::NOT_FOUND,
                "pairing_not_found",
                "no such pairing",
            ),
            Self::Store(error) => {
                tracing::error!(%error, "remote pairing management failed");
                manage_error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "pairing_store_unavailable",
                    "pairing store is unavailable",
                )
            }
        }
    }
}

fn manage_error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({ "error": { "code": code, "message": message } })),
    )
        .into_response()
}
