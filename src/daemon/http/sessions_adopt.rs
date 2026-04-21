use std::path::Path;
use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::daemon::protocol::SessionMutationResponse;
use crate::errors::CliError;
use crate::workspace::adopter::{AdoptionError, SessionAdopter};
use crate::workspace::harness_data_root;
use crate::workspace::layout::sessions_root;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

#[derive(Debug, serde::Deserialize)]
pub(super) struct AdoptRequest {
    #[serde(default)]
    pub bookmark_id: Option<String>,
    pub session_root: String,
}

pub(super) async fn post_session_adopt(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AdoptRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    // TODO: resolve bookmark_id via sandbox resolver when daemon runs sandboxed.
    let _ = request.bookmark_id;

    let result = adopt(&request.session_root);
    match result {
        Ok(payload) => timed_json(
            "POST",
            "/v1/sessions/adopt",
            &request_id,
            start,
            Ok::<_, CliError>(payload),
        ),
        Err(ref adoption_error) => adoption_error_response(adoption_error),
    }
}

fn adopt(session_root: &str) -> Result<SessionMutationResponse, AdoptionError> {
    let path = Path::new(session_root);
    let probed = SessionAdopter::probe(path)?;
    let data_root_sessions = sessions_root(&harness_data_root());
    let outcome = SessionAdopter::register(probed, &data_root_sessions)?;
    Ok(SessionMutationResponse {
        state: outcome.state,
    })
}

fn adoption_error_response(error: &AdoptionError) -> Response {
    let (status, body) = match error {
        AdoptionError::LayoutViolation { reason } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({ "error": "layout-violation", "reason": reason }),
        ),
        AdoptionError::UnsupportedSchemaVersion { found, supported } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({
                "error": "unsupported-schema-version",
                "found": found,
                "supported": supported
            }),
        ),
        AdoptionError::OriginMismatch { expected, found } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({
                "error": "origin-mismatch",
                "expected": expected,
                "found": found
            }),
        ),
        AdoptionError::AlreadyAttached { session_id } => (
            StatusCode::CONFLICT,
            serde_json::json!({ "error": "already-attached", "session_id": session_id }),
        ),
        AdoptionError::InvalidProjectDir
        | AdoptionError::Io { .. }
        | AdoptionError::Parse(_)
        | AdoptionError::Storage(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            serde_json::json!({ "error": "internal", "detail": error.to_string() }),
        ),
    };
    (status, Json(body)).into_response()
}

#[cfg(test)]
mod tests;
