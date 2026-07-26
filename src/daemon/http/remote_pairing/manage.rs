//! Listing pairings and revoking somebody else's device.
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
use crate::daemon::remote_pairing::{RemotePairingChange, RemotePairingInventoryEntry};
use crate::workspace::utc_now;
use harness_kernel::errors::CliError;

use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_response};
use super::super::remote_ws::publish_pairing_change;
use super::super::{DaemonHttpState, authenticated_remote_client, require_async_db};

pub(in crate::daemon::http) fn remote_pairing_manage_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_remote_pairings))
        .routes(routes!(post_remote_pairing_revoke))
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RemotePairingListResponse {
    /// Version of the daemon answering, so a client that already has to reach
    /// this route can report which daemon it is talking to without holding the
    /// broader `read` scope that `/v1/health` needs.
    daemon_version: String,
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
    description = "List pairing links and the devices they became, alongside the version of the daemon answering. Requires the pair_manage scope, which shows the caller the links it minted; a caller that also holds admin sees every pairing. Beyond the shared middleware causes, this route answers 503 when the pairing store is unavailable",
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
    // A caller that is not entitled to everything is authenticated by
    // definition, so the id is there. Defaulting a missing one to an empty
    // string would answer an authentication bug with an empty list instead.
    let owner = match client.as_ref() {
        Some(client) if !sees_every_pairing(Some(client)) => Some(client.client_id.as_str()),
        _ => None,
    };
    let pairings = db
        .list_remote_pairing_inventory(now.as_str(), owner)
        .map_err(RemotePairingManageError::Store)?;
    drop(db);

    Ok(RemotePairingListResponse {
        daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
        pairings,
    })
}

#[utoipa::path(
    post,
    path = "/v1/remote/pairings/{pairing_id}/revoke",
    tag = "pairing",
    params(("pairing_id" = String, Path, description = "Pairing to revoke")),
    description = "Revoke a pairing, cutting off somebody else's device rather than the caller's own credential. A claimed link cuts off the device it became; an unclaimed one can no longer be claimed. Requires the pair_manage scope, and the caller must have minted the pairing unless it also holds admin. Beyond the shared middleware causes, this route answers 503 when the pairing store is unavailable",
    responses(
        (status = 200, description = "Pairing revoked", body = RemotePairingRevokeResponse),
        (status = 403, description = "The pairing is not available to this caller: minted by another client, or no such id. The two are deliberately indistinguishable so the route cannot be used to discover which ids exist", body = DaemonErrorBody),
        (status = 404, description = "No such pairing, answered only to a caller entitled to see every pairing", body = DaemonErrorBody),
        (status = 503, description = "Pairing store unavailable", body = DaemonErrorBody),
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
    require_may_revoke(state, client.as_ref(), pairing_id, request_id)?;

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
    // Announced for an already-revoked pairing too. This request changed
    // nothing, but a subscriber that missed the original cut-off is exactly the
    // one whose view is wrong, and the event carries the state rather than the
    // transition, so a repeat is harmless.
    publish_pairing_change(state, RemotePairingChange::Revoked, pairing_id);
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
    request_id: &str,
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
        return Ok(());
    }
    // Recorded here rather than left to the store, which this refusal never
    // reaches. Walking the id space produces nothing but these refusals, so
    // without this the one case the indistinguishability exists for is the one
    // case that leaves no trace.
    record_refused_revoke(state, client, pairing_id, request_id);
    Err(RemotePairingManageError::NotYours)
}

/// Note a revoke that was refused before it reached the store.
///
/// Best effort: the caller is being refused either way, and failing the request
/// because the note could not be written would turn a denial into a fault.
fn record_refused_revoke(
    state: &DaemonHttpState,
    client: Option<&RemoteStoredClient>,
    pairing_id: &str,
    request_id: &str,
) {
    let recorded_at = utc_now();
    let Ok(audit) = revoke_audit(client, pairing_id, request_id, recorded_at.as_str()) else {
        return;
    };
    let audit = audit
        .with_outcome(RemoteAuditOutcome::Failure)
        .with_scope_decision(RemoteAuditScopeDecision::Denied);
    let Some(db) = state.db.get() else { return };
    let Ok(db) = db.lock() else { return };
    if let Err(error) = db.record_remote_audit_event(&audit) {
        tracing::warn!(%error, "could not record a refused pairing revoke");
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
                "REMOTE_PAIRING_STORE",
                "pairing store is unavailable",
            ),
            // One answer covers a pairing minted by somebody else and an id
            // that matches nothing, so it must not assert either. Saying the
            // pairing was minted by another client would be a lie for an id
            // that does not exist, and saying it does not exist would leak
            // which ids do.
            Self::NotYours => manage_error(
                StatusCode::FORBIDDEN,
                "REMOTE_PAIRING_NOT_AVAILABLE",
                "no pairing with that id is available to this client",
            ),
            Self::NotFound => manage_error(
                StatusCode::NOT_FOUND,
                "REMOTE_PAIRING_NOT_FOUND",
                "no such pairing",
            ),
            // Deliberately the same answer as `StoreUnavailable`: one means no
            // store is configured and the other that a call into it failed,
            // and which of the two it was is the daemon's business. They part
            // company in the log, which is where an operator looks.
            Self::Store(error) => {
                tracing::error!(%error, "remote pairing management failed");
                manage_error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "REMOTE_PAIRING_STORE",
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
