use std::time::Instant;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use serde::Serialize;
use uuid::Uuid;

use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{
    RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision,
};
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::response::{extract_request_id, timed_response};
use super::{DaemonHttpState, authenticated_remote_client, require_async_db};

pub(super) fn remote_client_routes() -> Router<DaemonHttpState> {
    Router::new().route(
        http_paths::REMOTE_CLIENT_SELF_REVOKE,
        post(post_remote_client_self_revoke),
    )
}

#[derive(Debug, Serialize)]
struct RemoteClientSelfRevokeResponse {
    client_id: String,
    revoked_at: String,
}

async fn post_remote_client_self_revoke(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    let response = match revoke_authenticated_client(&headers, &state, &request_id).await {
        Ok(response) => Json(response).into_response(),
        Err(error) => error.into_response(),
    };
    timed_response(
        "POST",
        http_paths::REMOTE_CLIENT_SELF_REVOKE,
        &request_id,
        start,
        response,
    )
}

async fn revoke_authenticated_client(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    request_id: &str,
) -> Result<RemoteClientSelfRevokeResponse, RemoteClientSelfRevokeError> {
    let client = authenticated_remote_client(headers, state)
        .map_err(RemoteClientSelfRevokeError::Authentication)?
        .ok_or(RemoteClientSelfRevokeError::RemoteModeRequired)?;
    let revoked_at = utc_now();
    let event_id = format!("remote-client-self-revoke-{}", Uuid::new_v4());
    let audit = RemoteAuditEvent::new(
        event_id,
        &revoked_at,
        Some(request_id),
        Some(&client.client_id),
        "remote.clients.self_revoke",
        RemoteAccessScope::Read,
        RemoteAuditScopeDecision::Allowed,
        RemoteAuditOutcome::Success,
        None,
        None,
    );
    let db = require_async_db(state, "self-revoke remote client")
        .map_err(RemoteClientSelfRevokeError::Store)?;
    let changed = db
        .revoke_remote_client_with_audit(&client.client_id, &revoked_at, &audit)
        .await
        .map_err(RemoteClientSelfRevokeError::Store)?;
    if !changed {
        return Err(RemoteClientSelfRevokeError::NoLongerActive);
    }
    Ok(RemoteClientSelfRevokeResponse {
        client_id: client.client_id,
        revoked_at,
    })
}

enum RemoteClientSelfRevokeError {
    Authentication(Box<Response>),
    RemoteModeRequired,
    NoLongerActive,
    Store(CliError),
}

impl IntoResponse for RemoteClientSelfRevokeError {
    fn into_response(self) -> Response {
        match self {
            Self::Authentication(response) => *response,
            Self::RemoteModeRequired => remote_client_revoke_error(
                StatusCode::BAD_REQUEST,
                "remote client self-revocation requires remote daemon mode",
            ),
            Self::NoLongerActive => remote_client_revoke_error(
                StatusCode::UNAUTHORIZED,
                "remote client credential is no longer active",
            ),
            Self::Store(error) => {
                log_revoke_store_error(&error);
                remote_client_revoke_error(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "remote client revocation store is unavailable",
                )
            }
        }
    }
}

fn remote_client_revoke_error(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({
            "error": {
                "code": "REMOTE_CLIENT_REVOKE",
                "message": message,
            }
        })),
    )
        .into_response()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_revoke_store_error(error: &CliError) {
    tracing::error!(error = %error, "remote client self-revocation failed");
}
