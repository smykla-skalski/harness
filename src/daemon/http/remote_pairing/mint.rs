//! Mint a pairing link for someone the caller has already authenticated.
//!
//! This is the one remote pairing route that is not public. It exists so a
//! companion service can hand a link to a person it vouches for without holding
//! shell access to the daemon host, and every link it creates names that person
//! in the pairing row and in the audit trail.

use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;
use uuid::Uuid;

use crate::daemon::db::DaemonDb;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteStoredClient,
    expand_client_scopes, parse_remote_role, parse_remote_scope,
};
use crate::daemon::remote_pairing::{
    RemotePairingCode, RemotePairingCreateParams, RemotePairingSubject, create_remote_pairing,
    pairing_expires_at,
};
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::super::DaemonHttpState;
use super::super::auth::authenticated_remote_client;
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json, timed_response};

/// Matches the CLI's `--ttl` default so a minted link and a locally created one
/// expire the same way when neither caller says otherwise.
const DEFAULT_MINT_TTL_SECONDS: u64 = 600;
/// A broker hands links to people who are expected to pair now. Anything longer
/// than a day is a standing credential in disguise.
const MAX_MINT_TTL_SECONDS: u64 = 24 * 60 * 60;

pub(super) fn remote_pairing_mint_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new().routes(routes!(post_remote_pair_mint))
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub(crate) struct RemotePairMintHttpRequest {
    /// Role granted to whoever claims the link, in wire form such as
    /// `operator`. `pairing_broker` is refused.
    role: String,
    /// Explicit scopes, which must be a subset of the role's. Omit to take the
    /// role's own scopes.
    #[serde(default)]
    scopes: Option<Vec<String>>,
    /// How long the link stays claimable. Omit to take the same ten minutes
    /// the CLI defaults to.
    #[serde(default)]
    // utoipa takes literals only, so `schema_bounds_match_the_enforced_ttl`
    // guards these against drifting from the constants above.
    #[schema(minimum = 1, maximum = 86400, default = 600)]
    ttl_seconds: Option<u64>,
    /// The external identity this link is for.
    subject: RemotePairingSubject,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RemotePairMintHttpResponse {
    pairing_id: String,
    role: String,
    scopes: Vec<String>,
    created_at: String,
    expires_at: String,
    ttl_seconds: u64,
    endpoint: String,
    server_spki_sha256: String,
    /// The invitation link. It already carries the one-time code, which is why
    /// no separate `code` field is returned.
    pairing_url: String,
    subject: RemotePairingSubject,
}

#[utoipa::path(
    post,
    path = "/v1/remote/pair/mint",
    tag = "pairing",
    request_body = RemotePairMintHttpRequest,
    description = "Mint a pairing link for an external identity the caller has already authenticated. Requires the pair_mint scope. The raw pairing code is not returned separately; it is carried inside pairing_url",
    responses(
        (status = 200, description = "Pairing link minted", body = RemotePairMintHttpResponse),
        (status = 400, description = "Malformed mint request", body = DaemonErrorBody),
        (status = 403, description = "Requested role or scope is not mintable", body = DaemonErrorBody),
        (status = 503, description = "Pairing store or remote identity unavailable", body = DaemonErrorBody),
    ),
)]
async fn post_remote_pair_mint(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RemotePairMintHttpRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    let client = match authenticated_remote_client(&headers, &state) {
        Ok(client) => client,
        Err(response) => {
            return timed_response(
                "POST",
                http_paths::REMOTE_PAIR_MINT,
                request_id.as_str(),
                start,
                *response,
            );
        }
    };
    match mint_remote_pairing(&state, &request, request_id.as_str(), client.as_ref()) {
        Ok(response) => timed_json(
            "POST",
            http_paths::REMOTE_PAIR_MINT,
            request_id.as_str(),
            start,
            Ok(response),
        ),
        Err(error) => timed_response(
            "POST",
            http_paths::REMOTE_PAIR_MINT,
            request_id.as_str(),
            start,
            error.into_response(),
        ),
    }
}

fn mint_remote_pairing(
    state: &DaemonHttpState,
    request: &RemotePairMintHttpRequest,
    request_id: &str,
    client: Option<&RemoteStoredClient>,
) -> Result<RemotePairMintHttpResponse, RemotePairMintHttpError> {
    let plan = MintPlan::from_request(request)?;
    let code = RemotePairingCode::generate();
    let created_at = utc_now();
    let expires_at = pairing_expires_at(created_at.as_str(), plan.ttl_seconds)
        .map_err(|_| RemotePairMintHttpError::InvalidTtl)?;
    let pairing_id = format!("pairing-{}", Uuid::new_v4());
    let audit_event_id = format!("remote-pair-mint-{}", Uuid::new_v4());
    let db = state
        .db
        .get()
        .ok_or(RemotePairMintHttpError::StoreUnavailable)?
        .lock()
        .map_err(|_| RemotePairMintHttpError::StoreUnavailable)?;
    let created = create_remote_pairing(
        &db,
        &RemotePairingCreateParams {
            pairing_id: pairing_id.as_str(),
            audit_event_id: audit_event_id.as_str(),
            code: &code,
            created_at: created_at.as_str(),
            expires_at: expires_at.as_str(),
            ttl_seconds: plan.ttl_seconds,
            role: plan.role,
            requested_scopes: &plan.scopes,
            reviews_query: None,
            minted_for: Some(&request.subject),
        },
    )
    .map_err(RemotePairMintHttpError::Create)?;
    record_mint_audit_event(
        &db,
        request_id,
        client,
        &request.subject,
        &created.pairing_id,
    )
    .map_err(RemotePairMintHttpError::Create)?;
    drop(db);
    log_remote_pairing_minted(request_id, created.pairing_id.as_str());
    Ok(RemotePairMintHttpResponse {
        pairing_id: created.pairing_id,
        role: created.role,
        scopes: created.scopes,
        created_at: created.created_at,
        expires_at: created.expires_at,
        ttl_seconds: created.ttl_seconds,
        endpoint: created.endpoint,
        server_spki_sha256: created.server_spki_sha256,
        pairing_url: created.pairing_url,
        subject: request.subject.clone(),
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_remote_pairing_minted(request_id: &str, pairing_id: &str) {
    tracing::debug!(request_id, pairing_id, "remote pairing minted");
}

/// The `remote.pair.create` event the store writes says a link was made. This
/// one says who asked and who it was for, which is the question an operator
/// reading the trail after the fact actually has.
///
/// The context rides `metadata_json`, not `error_detail`. This event is a
/// success, and every other writer sets `error_detail` only on failure, so a
/// reader treating it as a failure signal would misclassify every mint.
fn record_mint_audit_event(
    db: &DaemonDb,
    request_id: &str,
    client: Option<&RemoteStoredClient>,
    subject: &RemotePairingSubject,
    pairing_id: &str,
) -> Result<(), CliError> {
    let event_id = format!("remote-pair-mint-audit-{}", Uuid::new_v4());
    let metadata = serde_json::json!({
        "pairing_id": pairing_id,
        "minted_for": subject,
    })
    .to_string();
    db.record_remote_audit_event(
        &RemoteAuditEvent::new(
            event_id.as_str(),
            utc_now().as_str(),
            Some(request_id),
            client.map(|client| client.client_id.as_str()),
            "remote.pair.mint",
            RemoteAccessScope::PairMint,
            RemoteAuditScopeDecision::Allowed,
            RemoteAuditOutcome::Success,
            None,
            None,
        )
        .with_metadata_json(metadata),
    )
}

struct MintPlan {
    role: RemoteRole,
    scopes: Vec<RemoteAccessScope>,
    ttl_seconds: u64,
}

impl MintPlan {
    fn from_request(request: &RemotePairMintHttpRequest) -> Result<Self, RemotePairMintHttpError> {
        let role =
            parse_remote_role(request.role.trim()).ok_or(RemotePairMintHttpError::UnknownRole)?;
        // Otherwise a broker credential could mint another broker credential,
        // and revoking the original would no longer stop the minting.
        if role == RemoteRole::PairingBroker {
            return Err(RemotePairMintHttpError::RoleNotMintable);
        }
        let requested = request
            .scopes
            .as_deref()
            .unwrap_or_default()
            .iter()
            .map(|scope| {
                parse_remote_scope(scope.trim()).ok_or(RemotePairMintHttpError::UnknownScope)
            })
            .collect::<Result<Vec<_>, _>>()?;
        // Expanding here rather than leaving it to the shared create path keeps
        // "you asked for a scope your role does not have" a 403 about the
        // request instead of a 503 about the daemon.
        let scopes = expand_client_scopes(role, &requested)
            .map_err(|error| RemotePairMintHttpError::ScopeNotAllowed(error.to_string()))?;
        let ttl_seconds = request.ttl_seconds.unwrap_or(DEFAULT_MINT_TTL_SECONDS);
        if ttl_seconds == 0 || ttl_seconds > MAX_MINT_TTL_SECONDS {
            return Err(RemotePairMintHttpError::InvalidTtl);
        }
        request
            .subject
            .validate()
            .map_err(|error| RemotePairMintHttpError::InvalidSubject(error.to_string()))?;
        Ok(Self {
            role,
            scopes,
            ttl_seconds,
        })
    }
}

#[derive(Debug)]
enum RemotePairMintHttpError {
    UnknownRole,
    UnknownScope,
    ScopeNotAllowed(String),
    RoleNotMintable,
    InvalidTtl,
    InvalidSubject(String),
    StoreUnavailable,
    Create(CliError),
}

impl IntoResponse for RemotePairMintHttpError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::UnknownRole => (
                StatusCode::BAD_REQUEST,
                "REMOTE_PAIR_MINT_ROLE",
                "remote pairing role is unknown".to_owned(),
            ),
            Self::UnknownScope => (
                StatusCode::BAD_REQUEST,
                "REMOTE_PAIR_MINT_SCOPE",
                "remote pairing scope is unknown".to_owned(),
            ),
            Self::ScopeNotAllowed(detail) => {
                (StatusCode::FORBIDDEN, "REMOTE_PAIR_MINT_SCOPE", detail)
            }
            Self::RoleNotMintable => (
                StatusCode::FORBIDDEN,
                "REMOTE_PAIR_MINT_ROLE",
                "the pairing_broker role cannot be minted".to_owned(),
            ),
            Self::InvalidTtl => (
                StatusCode::BAD_REQUEST,
                "REMOTE_PAIR_MINT_TTL",
                format!("remote pairing ttl must be between 1 and {MAX_MINT_TTL_SECONDS} seconds"),
            ),
            Self::InvalidSubject(detail) => {
                (StatusCode::BAD_REQUEST, "REMOTE_PAIR_MINT_SUBJECT", detail)
            }
            Self::StoreUnavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "REMOTE_PAIRING_STORE",
                "remote pairing store is unavailable".to_owned(),
            ),
            // Scope expansion, the missing-TLS-identity case, and persistence
            // all land here. The detail stays in the daemon log: a broker is
            // not entitled to the daemon's internal failure text.
            Self::Create(error) => {
                log_mint_failure(&error);
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "REMOTE_PAIR_MINT",
                    "remote pairing could not be minted".to_owned(),
                )
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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_mint_failure(error: &CliError) {
    tracing::error!(%error, "remote pairing mint failed");
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_MINT_TTL_SECONDS, MAX_MINT_TTL_SECONDS, RemotePairMintHttpRequest};
    use utoipa::PartialSchema as _;

    /// The published bounds are literals because utoipa accepts nothing else,
    /// so nothing but this test stops them drifting from what the handler
    /// enforces and telling callers a TTL the route would reject.
    #[test]
    fn schema_bounds_match_the_enforced_ttl() {
        let schema = serde_json::to_value(RemotePairMintHttpRequest::schema())
            .expect("serialize request schema");
        let ttl = &schema["properties"]["ttl_seconds"];

        assert_eq!(ttl["minimum"], 1, "{schema}");
        assert_eq!(ttl["maximum"], MAX_MINT_TTL_SECONDS, "{schema}");
        assert_eq!(ttl["default"], DEFAULT_MINT_TTL_SECONDS, "{schema}");
    }
}
